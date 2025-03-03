module sensitivity

using Logging
using DataFrames, NamedDims, AxisKeys
using Distributions, HypothesisTests, Bootstrap, StaticArrays

using ADRIA: ResultSet
using ADRIA.analysis: col_normalize


"""
    ks_statistic(ks)

Calculate the Kolmogorov-Smirnov test statistic.
"""
function ks_statistic(ks)
    n = (ks.n_x * ks.n_y) / (ks.n_x + ks.n_y)

    return sqrt(n) * ks.δ
end


"""
    pawn(X::T1, y::T2, dimnames::Vector{String}; S::Int64=10)::NamedDimsArray where {T1<:AbstractArray{<:Real},T2<:AbstractVector{<:Real}}

Calculates the PAWN sensitivity index.

The PAWN method (by Pianosi and Wagener) is a moment-independent approach to Global Sensitivity Analysis.
Outputs are characterized by their Cumulative Distribution Function (CDF), quantifying the variation in
the output distribution after conditioning an input over "slices" (\$S\$) - the conditioning intervals.
If both distributions coincide at all slices (i.e., the distributions are similar or identical), then
the factor is deemed non-influential.

This implementation applies the Kolmogorov-Smirnov test as the distance measure and returns summary
statistics (min, mean, median, max, std, and cv) over the slices.

# Arguments
- `X` : Model inputs
- `y` : Model outputs
- `factor_names` : Names of each factor represented by columns in `X`
- `S` : Number of slides (default: 10)

# Returns
NamedDimsArray, of min, mean, median, max, std, and cv summary statistics.

# References
1. Pianosi, F., Wagener, T., 2018.
   Distribution-based sensitivity analysis from a generic input-output sample.
   Environmental Modelling & Software 108, 197-207.
   https://doi.org/10.1016/j.envsoft.2018.07.019

2. Baroni, G., Francke, T., 2020.
   GSA-cvd
   Combining variance- and distribution-based global sensitivity analysis
   https://github.com/baronig/GSA-cvd
"""
function pawn(X::T1, y::T2, factor_names::Vector{String}; S::Int64=10)::NamedDimsArray where {T1<:AbstractArray{<:Real},T2<:AbstractVector{<:Real}}
    N, D = size(X)
    step = 1 / S
    seq = 0.0:step:1.0

    X_di = @MVector zeros(N)
    X_q = @MVector zeros(S + 1)
    pawn_t = @MArray zeros(S, D)
    results = @MArray zeros(D, 6)
    # Hide warnings from HypothesisTests
    with_logger(NullLogger()) do
        for d_i in 1:D
            X_di .= X[:, d_i]
            X_q .= quantile(X_di, seq)

            Y_sel = y[X_q[1].<=X_di.<=X_q[2]]
            if length(Y_sel) > 0
                pawn_t[1, d_i] = ks_statistic(ApproximateTwoSampleKSTest(Y_sel, y))
            end

            for s in 2:S
                Y_sel = y[X_q[s].<X_di.<=X_q[s+1]]
                if length(Y_sel) == 0
                    continue  # no available samples
                end

                pawn_t[s, d_i] = ks_statistic(ApproximateTwoSampleKSTest(Y_sel, y))
            end

            p_ind = pawn_t[:, d_i]
            p_mean = mean(p_ind)
            p_sdv = std(p_ind)
            p_cv = p_sdv ./ p_mean
            results[d_i, :] .= (minimum(p_ind), p_mean, median(p_ind), maximum(p_ind), p_sdv, p_cv)
        end
    end

    replace!(results, NaN => 0.0, Inf => 0.0)

    return NamedDimsArray(results; factors=Symbol.(factor_names), Si=[:min, :mean, :median, :max, :std, :cv])
end
function pawn(X::AbstractArray{<:Real}, y::NamedDimsArray, factor_names::Vector{String}; S::Int64=10)::NamedDimsArray
    return pawn(X, vec(y), factor_names; S=S)
end
function pawn(X::DataFrame, y::AbstractVector; S::Int64=10)::NamedDimsArray
    return pawn(Matrix(X), y, names(X); S=S)
end
function pawn(X::NamedDimsArray, y::T; S::Int64=10)::NamedDimsArray where {T<:Union{NamedDimsArray,AbstractVector{<:Real}}}
    return pawn(X, y, axiskeys(X, 2); S=S)
end
function pawn(rs::ResultSet, y::T; S::Int64=10)::NamedDimsArray where {T<:Union{NamedDimsArray,AbstractVector{<:Real}}}
    return pawn(rs.inputs, y; S=S)
end


"""
    tsa(X::DataFrame, y::AbstractMatrix)::NamedDimsArray

Perform Temporal (or time-varying) Sensitivity Analysis using the PAWN sensitivity index.

The sensitivity index value for time \$t\$ is inclusive of all time steps prior to \$t\$.
Alternate approaches use a moving window, or only data for time \$t\$.

# Examples
```julia
rs = ADRIA.load_results("a ResultSet of interest")

# Get scenario outcomes over time (shape: `time ⋅ scenarios`)
y_tac = ADRIA.metrics.scenario_total_cover(rs)

# Calculate sensitivity of outcome to factors for each time step
ADRIA.sensitivity.tsa(rs.inputs, y_tac)
```

# Arguments
- `X` : Scenario specification
- `y` : scenario outcomes over time

# Returns
NamedDimsArray, of shape \$D\$ ⋅ 6 ⋅ \$T\$, where
- \$D\$ is the number of dimensions/factors
- 6 corresponds to the min, mean, median, max, std, and cv of the PAWN indices
- \$T\$ is the number of time steps
"""
function tsa(X::DataFrame, y::AbstractMatrix{<:Real})::NamedDimsArray
    local ts
    try
        ts = axiskeys(y, 1)
    catch err
        if err isa MethodError
            ts = 1:size(y, 1)
        else
            rethrow(err)
        end
    end

    t_pawn_idx = NamedDimsArray(
        zeros(ncol(X), 6, size(y, 1));
        factors=Symbol.(names(X)),
        Si=[:min, :mean, :median, :max, :std, :cv],
        timesteps=ts
    )

    for t in axes(y, 1)
        t_pawn_idx[:, :, t] .= col_normalize(
            pawn(X, vec(mean(y[1:t, :], dims=1)))
        )
    end

    return t_pawn_idx
end
function tsa(rs::ResultSet, y::AbstractMatrix{<:Real})::NamedDimsArray
    return tsa(rs.inputs, y)
end

"""
    rsa(X::DataFrame, y::Vector{<:Real}; S=10)::NamedDimsArray
    rsa(rs::ResultSet, y::AbstractArray{<:Real}; S::Int64=10)::NamedDimsArray

Perform Regional Sensitivity Analysis.

Regional Sensitivity Analysis is a Monte Carlo Filtering approach which aims to
identify which (group of) factors drive model outputs within or outside of a specified bound.
Outputs which fall inside the bounds are regarded as "behavioral", whereas those outside
are "non-behavioral". The distribution of behavioral/non-behavioral subsets are compared for each
factor. If the subsets are not similar, then the factor is influential. The sensitivity index is
simply the maximum distance between the two distributions, with larger values indicating greater
sensitivity.

The implemented approach slices factor space into \$S\$ bins and iteratively assesses
behavioral (samples within the bin) and non-behavioral (out of bin samples) subsets with the
non-parametric \$k\$-sample Anderson-Darling test. Larger values indicate greater dissimilarity
(thus, sensitivity). The Anderson-Darling test places more weight on the tails compared to the
Kolmogorov-Smirnov test.

RSA can indicate where in factor space model sensitivities may be, and contributes to a
Value-of-Information (VoI) analysis.

Increasing the value of \$S\$ increases the granularity of the analysis, but necessitates larger
sample sizes.

Note: Values of type `missing` indicate a lack of samples in the region.

# Arguments
- `X` : scenario specification
- `y` : scenario outcomes
- `S` : number of bins to slice factor space into (default: 10)

# Returns
NamedDimsArray, [bin values, factors]

# Examples
```julia
ADRIA.sensitivity.rsa(X, y; S=10)
```

# References
1. Pianosi, F., K. Beven, J. Freer, J. W. Hall, J. Rougier, D. B. Stephenson, and
   T. Wagener. 2016.
   Sensitivity analysis of environmental models:
   A systematic review with practical workflow.
   Environmental Modelling & Software 79:214-232.
   https://dx.doi.org/10.1016/j.envsoft.2016.02.008

2. Saltelli, A., M. Ratto, T. Andres, F. Campolongo, J. Cariboni, D. Gatelli,
   M. Saisana, and S. Tarantola. 2008.
   Global Sensitivity Analysis: The Primer.
   Wiley, West Sussex, U.K.
   https://dx.doi.org/10.1002/9780470725184
   Accessible at: http://www.andreasaltelli.eu/file/repository/Primer_Corrected_2022.pdf
"""
function rsa(X::DataFrame, y::AbstractVector{<:Real}; S::Int64=10)::NamedDimsArray
    N, D = size(X)
    seq = collect(0.0:(1/S):1.0)

    X_di = @MVector zeros(N)
    X_q = @MVector zeros(S + 1)
    r_s = zeros(Union{Missing,Float64}, S, D)
    sel = trues(N)

    for d_i in 1:D
        X_di .= X[:, d_i]
        X_q .= quantile(X_di, seq)

        sel .= X_q[1] .<= X_di .<= X_q[2]
        if count(sel) == 0 || length(y[Not(sel)]) == 0 || length(unique(y[sel])) == 1
            # not enough samples, or inactive area of factor space
            r_s[1, d_i] = missing
        else
            r_s[1, d_i] = KSampleADTest(y[sel], y[Not(sel)]).A²k
        end

        for s in 2:S
            sel .= X_q[s] .< X_di .<= X_q[s+1]
            if count(sel) == 0 || length(y[Not(sel)]) == 0 || length(unique(y[sel])) == 1
                # not enough samples, or inactive area of factor space
                r_s[s, d_i] = missing
                continue
            end

            # bs = bootstrap(mean, y[b], BalancedSampling(n_boot))
            # ci = confint(bs, PercentileConfInt(conf))[1]
            r_s[s, d_i] = KSampleADTest(y[sel], y[Not(sel)]).A²k
        end
    end

    return col_normalize(NamedDimsArray(r_s; bins=string.(seq[2:end]), factors=Symbol.(names(X))))
end
function rsa(rs::ResultSet, y::AbstractVector{<:Real}; S::Int64=10)::NamedDimsArray
    return rsa(rs.inputs, vec(y); S=S)
end


"""
    outcome_map(X::DataFrame, y::AbstractVecOrMat, rule, target_factors::Vector; S::Int=20, n_boot::Int=100, conf::Float64=0.95)::NamedDimsArray

Map normalized outcomes (defined by `rule`) to factor values discretized into `S` bins.

Produces a matrix indicating the range of (normalized) outcomes across factor space for
each dimension (the model inputs). This is similar to a Regional Sensitivity Analysis,
except that the model outputs are examined directly as opposed to a measure of sensitivity.

Note:
- `y` is normalized on a per-column basis prior to the analysis
- Empty areas of factor space (those that do not have any desired outcomes)
  will be assigned `NaN`

# Arguments
- `X` : scenario specification
- `y` : Vector or Matrix of outcomes corresponding to scenarios in `X`
- `rule` : a callable defining a "desirable" scenario outcome
- `target_factors` : list of factors of interest to perform analyses on
- `S` : number of slices of factor space. Higher values equate to finer granularity
- `n_boot` : number of bootstraps (default: 100)
- `conf` : confidence interval (default: 0.95)

# Returns
3-dimensional NamedDimsArray, of shape \$S\$ ⋅ \$D\$ ⋅ 3, where:
- \$S\$ is the slices,
- \$D\$ is the number of dimensions, with
- boostrapped mean (dim 1) and the lower/upper 95% confidence interval (dims 2 and 3).

# Examples
```julia
# Factors of interest
foi = [:SRM, :fogging, :a_adapt]

# Find scenarios where all metrics are above their median
rule = y -> all(y .> 0.5)

# Map input values where to their outcomes
ADRIA.sensitivity.outcome_map(X, y, rule, foi; S=20, n_boot=100, conf=0.95)
```
"""
function outcome_map(X::DataFrame, y::AbstractVecOrMat{T}, rule::V, target_factors::Vector; S::Int64=20, n_boot::Int64=100, conf::Float64=0.95)::NamedDimsArray where {T<:Real,V<:Union{Function,BitVector,Vector{Int64}}}
    step_size = 1 / S
    steps = collect(0:step_size:1.0)

    p_table = NamedDimsArray(
        zeros(Union{Missing,Float64}, length(steps) - 1, length(target_factors), 3);
        bins=["$(round(i, digits=2))" for i in steps[2:end]],
        factors=Symbol.(target_factors),
        CI=[:mean, :lower, :upper]
    )

    all_p_rule = _map_outcomes(y, rule)
    if length(all_p_rule) == 0
        @warn "Empty result set"
        return p_table
    end

    # Identify behavioural
    n_scens = size(X, 1)
    behave = zeros(Bool, n_scens)
    behave[all_p_rule] .= true

    X_q = zeros(S + 1)
    for (j, fact_t) in enumerate(target_factors)
        X_q .= quantile(X[:, fact_t], steps)
        for (i, s) in enumerate(X_q[1:end-1])
            b = i == 1 ? (X_q[i] .<= X[:, fact_t] .<= X_q[i+1]) .& behave : (X_q[i] .< X[:, fact_t] .<= X_q[i+1]) .& behave
            if count(b) == 0
                p_table[i, j, 1] = missing
                p_table[i, j, 2] = missing
                p_table[i, j, 3] = missing
                continue
            end

            bs = bootstrap(mean, y[b], BalancedSampling(n_boot))
            ci = confint(bs, PercentileConfInt(conf))[1]

            p_table[i, j, 1] = ci[1]
            p_table[i, j, 2] = ci[2]
            p_table[i, j, 3] = ci[3]
        end
    end

    return p_table
end
function outcome_map(X::DataFrame, y::AbstractVecOrMat{T}, rule::V; S::Int64=20, n_boot::Int64=100, conf::Float64=0.95)::NamedDimsArray where {T<:Real,V<:Union{Function,BitVector,Vector{Int64}}}
    return outcome_map(X, y, rule, names(X); S, n_boot, conf)
end
function outcome_map(rs::ResultSet, y::AbstractArray, rule::V, target_factors::Vector; S::Int64=20, n_boot::Int64=100, conf::Float64=0.95)::NamedDimsArray where {V<:Union{Function,BitVector,Vector{Int64}}}
    return outcome_map(rs.inputs, y, rule, target_factors; S, n_boot, conf)
end
function outcome_map(rs::ResultSet, y::AbstractArray, rule::V; S::Int64=20, n_boot::Int64=100, conf::Float64=0.95)::NamedDimsArray where {V<:Union{Function,BitVector,Vector{Int64}}}
    return outcome_map(rs.inputs, y, rule, names(rs.inputs); S, n_boot, conf)
end

function _map_outcomes(y::AbstractArray, rule::Union{BitVector,Vector{Int64}})
    return rule
end
function _map_outcomes(y::AbstractArray, rule::Function)
    _y = col_normalize(y)
    all_p_rule = findall(rule, eachrow(_y))

    return all_p_rule
end

end