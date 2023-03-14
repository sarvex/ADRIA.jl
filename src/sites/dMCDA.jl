"""Objects and methods for Dynamic Multi-Criteria Decision Analysis/Making"""

using StatsBase
using Distances
using Combinatorics

struct DMCDA_vars  # {V, I, F, M} where V <: Vector
    n_site_int  # ::I
    crit_seed_names #::V
    crit_shade_names #::V
    weights #::V
    thesholds #::V
    distances #::M
    use_dist #::I
    min_dist #::I
    top_n #::I
end

function create_criteria_df(site_ids::AbstractArray, coral_cover::AbstractArray,
    coral_space::AbstractArray, connectivity_in::AbstractArray, connectivity_out::AbstractArray,
    heat_stress::AbstractArray, wave_stress::AbstractArray, criteria...)::DataFrame

    criteria_df = DataFrame(site_ids=site_ids, coral_cover=coral_cover, coral_space=coral_space,
        connectivity_in=connectivity_in, connectivity_out=connectivity_out,
        heat_stress=heat_stress, wave_stress=wave_stress)

    for crit_temp in criteria
        criteria_df[!, @Name(crit_temp)] = crit_temp
    end
    return criteria_df
end

function create_weights_df(coral_cover_wt::Float64, coral_space_wt::Float64,
    in_seed_connectivity_wt::Float64, out_seed_connectivity_wt::Float64,
    shade_connectivity_wt::Float64, heat_stress_wt::Float64,
    wave_stress_wt::Float64, weights...)::DataFrame

    weights_df = DataFrame(coral_cover_wt=coral_cover_wt, coral_space_wt=coral_space_wt,
        in_seed_connectivity_wt=in_seed_connectivity_wt,
        out_seed_connectivity_wt=out_seed_connectivity_wt,
        shade_connectivity_wt=shade_connectivity_wt, heat_stress_wt=heat_stress_wt,
        wave_stress_wt=wave_stress_wt)

    for wt_temp in weights
        weights_df[!, @Name(wt_temp)] = wt_temp
    end
    return weights_df
end

function create_thesholds_df(coral_space_th::Float64, heat_stress_th::Float64,
    wave_stress_th::Float64, thresholds...)::DataFrame

    thresholds_df = DataFrame(coral_space_th=coral_space_th, heat_stress_th=heat_stress_th,
        wave_stress_th=wave_stress_th)

    for th_temp in thresholds
        thresholds_df[!, @Name(th_temp)] = th_temp
    end
    return thresholds_df
end

"""
    DMCDA_vars(domain::Domain, criteria::NamedDimsArray,
               site_ids::AbstractArray, sum_cover::AbstractArray, area_to_seed::Float64,
               waves::AbstractArray, dhws::AbstractArray)::DMCDA_vars
    DMCDA_vars(domain::Domain, criteria::NamedDimsArray, site_ids::AbstractArray,
               sum_cover::AbstractArray, area_to_seed::Float64)::DMCDA_vars
    DMCDA_vars(domain::Domain, criteria::DataFrameRow, site_ids::AbstractArray,
               sum_cover::AbstractArray, area_to_seed::Float64)::DMCDA_vars
    DMCDA_vars(domain::Domain, criteria::DataFrameRow, site_ids::AbstractArray,
               sum_cover::AbstractArray, area_to_seed::Float64,
               waves::AbstractArray, dhw::AbstractArray)::DMCDA_vars

Constuctors for DMCDA variables.
"""
function DMCDA_vars(domain::Domain, seed_crit_names::Vector{String}, shade_crit_names::Vector{String},
    use_dist::Float64, min_dist::Float64, top_n::Int64, weights::DataFrame, thresholds::DataFrame)::DMCDA_vars

    mcda_vars = DMCDA_vars(
        domain.sim_constants.n_site_int,
        seed_crit_names,
        shade_crit_names,
        weights,
        thresholds,
        domain.distances,
        use_dist,
        min_dist,
        top_n
    )

    return mcda_vars
end

"""
    mcda_normalize(x::Vector)::Vector

Normalize a Vector (wse/wsh) for MCDA.
"""
function mcda_normalize(x::Vector)::Vector
    return x ./ sum(x)
end

"""
    mcda_normalize(x::Matrix)::Matrix

Normalize a Matrix (SE/SH) for MCDA.
"""
function mcda_normalize(x::Matrix)::Matrix
    return x ./ sqrt.(sum(x .^ 2, dims=1))
end


"""
    align_rankings!(rankings::Array, s_order::Matrix, col::Int64)::Nothing

Align a vector of site rankings to match the indicated order in `s_order`.
"""
function align_rankings!(rankings::Array, s_order::Matrix, col::Int64)::Nothing
    # Fill target ranking column
    for (i, site_id) in enumerate(s_order[:, 1])
        rankings[rankings[:, 1].==site_id, col] .= s_order[i, 3]
    end

    return
end

"""
    rank_sites!(S, weights, rankings, n_site_int, rank_col)
    rank_seed_sites!(S, weights, rankings, n_site_int)
    rank_shade_sites!(S, weights, rankings, n_site_int)

# Arguments
- `S` : Matrix, Site preference values
- `weights` : weights to apply
- `rankings` : vector of site ranks to update
- `n_site_int` : number of sites to select for interventions
- `rank_col` : column to fill with rankings (2 for seed, 3 for shade)

# Returns
- `prefsites` : sites in order of their rankings
"""
function rank_sites!(S, weights, rankings, n_site_int, mcda_func, rank_col)::Tuple{Vector{Int64},Matrix{Union{Float64,Int64}}}
    # Filter out all non-preferred sites
    selector = vec(.!all(S[:, 2:end] .== 0, dims=1))

    # weights in order of: in_conn, out_conn, wave, heat, predecessors, low cover
    weights = weights[selector]
    S = S[:, Bool[1, selector...]]

    # Skip first column as this holds site index ids
    S[:, 2:end] = mcda_normalize(S[:, 2:end])
    S[:, 2:end] .= S[:, 2:end] .* repeat(weights', size(S[:, 2:end], 1), 1)
    s_order = mcda_func(S)

    last_idx = min(n_site_int, size(s_order, 1))
    prefsites = Int.(s_order[1:last_idx, 1])

    # Match by site_id and assign rankings to log
    align_rankings!(rankings, s_order, rank_col)

    return prefsites, s_order
end

function rank_seed_sites!(S, weights, rankings, n_site_int, mcda_func)::Tuple{Vector{Int64},Matrix{Union{Float64,Int64}}}
    rank_sites!(S, weights, rankings, n_site_int, mcda_func, 2)
end
function rank_shade_sites!(S, weights, rankings, n_site_int, mcda_func)::Tuple{Vector{Int64},Matrix{Union{Float64,Int64}}}
    rank_sites!(S, weights, rankings, n_site_int, mcda_func, 3)
end

function create_decision_matrix(criteria_df::DataFrame, tolerances::Vector{Tuple{String,String,Float64}})
    A = Matrix(criteria_df)
    crit_col = criteria_df.fieldname .== tolerances[tt][1]
    for tt = 1:length(tolerances)
        if tolerances[tt][2] .== "gt"
            rule = A[:, crit_col] .> tolerances[tt][3]
        elseif tolerances[tt][2] .== "lt"
            rule = A[:, crit_col] .<= tolerances[tt][3]
        end
        A[rule, crit_col] .= NaN
    end

    # Filter out sites not satisfying the tolerances
    filtered = vec(.!any(isnan.(A), dims=2))
    # remove rows with NaNs
    A = A[filtered, :]
    return A, filtered
end



function create_intervention_matrix(A, weights, criteria_df, int_crit_names)
    # Define intervention decision matrix
    crit_names = names(criteria_df)
    int_ind = [findall(crit_names .== int_crit_names[ind]) for ind in eachindex(int_crit_names)]
    S = A[:, int_ind]
    ws = normalize(weights[int_ind])
    return S, ws
end


"""
    guided_site_selection(d_vars::DMCDA_vars, criteria_df::DataFrame, alg_ind::Int64, log_seed::Bool, log_shade::Bool, prefseedsites::AbstractArray{Int64}, prefshadesites::AbstractArray{Int64}, rankingsin::Matrix{Int64})

# Arguments
- `d_vars` : DMCDA_vars type struct containing weightings and criteria values for site selection.
- `alg_ind` : integer indicating MCDA aggregation method to use (0: none, 1: order ranking, 2:topsis, 3: vikor)
- `log_seed` : boolean indicating whether seeding sites are being re-assesed at current time
- `log_shade` : boolean indicating whether shading/fogging sites are being re-assesed at current time
- `prefshadesites` : previous time step's selection of sites for shading
- `prefseedsites` : previous time step's selection of sites for seeding
- `rankingsin` : pre-allocated store for site rankings

# Returns
Tuple :
    - `prefseedsites` : n_site_int highest ranked seeding sites
    - `prefshadesites` : n_site_int highest ranked shading/fogging sites
    - `rankings` : n_sites ⋅ 3 matrix holding [site_id, seeding_rank, shading_rank],
        Values of 0 indicate sites that were not considered
"""
function guided_site_selection(
    d_vars::DMCDA_vars, criteria_df::DataFrame,
    alg_ind::T, log_seed::B, log_shade::B,
    prefseedsites::IA, prefshadesites::IA,
    rankingsin::Matrix{T}
)::Tuple where {T<:Int64,IA<:AbstractArray{<:Int64},IB<:AbstractArray{<:Int64},B<:Bool}

    site_ids::Array{Int64} = criteria_df[:, :site_ids]
    use_dist::Int64 = d_vars.use_dist
    min_dist::Float64 = d_vars.min_dist
    site_ids = copy(d_vars.site_ids)

    # Force different sites to be selected
    site_ids = setdiff(site_ids, hcat(prefseedsites, prefshadesites))
    mod_n_ranks = min(size(rankingsin, 1), length(site_ids))
    if mod_n_ranks < length(d_vars.site_ids) && length(rankingsin) != 0
        rankingsin = rankingsin[in.(rankingsin[:, 1], [site_ids]), :]
        site_ids = rankingsin[:, 1]
    elseif length(rankingsin) != 0
        rankingsin = [site_ids zeros(Int64, length(site_ids)) zeros(Int64, length(site_ids))]
    end

    n_sites::Int64 = length(site_ids)

    # if no sites are available, abort
    if n_sites == 0
        return prefseedsites, prefshadesites, rankingsin
    end

    n_site_int::Int64 = d_vars.n_site_int
    tolerances = d_vars.tolerances
    weights = d_vars.weights
    # site_id, seeding rank, shading rank
    rankings = Int64[site_ids zeros(Int64, n_sites) zeros(Int64, n_sites)]

    A, filtered_sites = create_decision_matrix(criteria_df, tolerances)
    if isempty(A)
        # if all rows have nans and A is empty, abort mission
        return prefseedsites, prefshadesites, rankingsin
    end

    # cap to number of sites left after risk filtration
    n_site_int = min(n_site_int, length(A[:, 1]))

    # if seeding, create seeding specific decision matrix
    if log_seed
        SE, wse = create_intervention_matrix(A, weights, criteria_df, d_vars.seed_crit_names)
    end

    # if shading, create shading specific decision matrix
    if log_shade
        SH, wsh = create_intervention_matrix(A, weights, criteria_df, d_vars.shade_crit_names)
    end

    if alg_ind == 1
        mcda_func = order_ranking
    elseif alg_ind == 2
        mcda_func = topsis
    elseif alg_ind == 3
        mcda_func = vikor
    else
        error("Unknown MCDA algorithm selected. Valid options are 1 (Order Ranking), 2 (TOPSIS) and 3 (VIKOR).")
    end

    if log_seed && isempty(SE)
        prefseedsites = repeat([0], n_site_int)
    elseif log_seed

        prefseedsites, s_order_seed = rank_seed_sites!(SE, wse, rankings, n_site_int, mcda_func)
        if use_dist != 0
            prefseedsites, rankings = distance_sorting(prefseedsites, s_order_seed, d_vars.dist, min_dist, Int64(d_vars.top_n), rankings, 2)
        end
    end

    if log_shade && isempty(SH)
        prefshadesites = repeat([0], n_site_int)
    elseif log_shade
        prefshadesites, s_order_shade = rank_shade_sites!(SH, wsh, rankings, n_site_int, mcda_func)
        if use_dist != 0
            prefshadesites, rankings = distance_sorting(prefshadesites, s_order_shade, d_vars.dist, min_dist, Int64(d_vars.top_n), rankings, 3)
        end
    end

    # Replace with input rankings if seeding or shading rankings have not been filled
    if sum(prefseedsites) == 0
        rankings[:, 2] .= rankingsin[:, 2]
    end

    if sum(prefshadesites) == 0
        rankings[:, 3] .= rankingsin[:, 3]
    end

    return prefseedsites, prefshadesites, rankings
end

"""
    distance_sorting(pref_sites::AbstractArray{Int}, site_order::AbstractVector, dist::Array{Float64}, dist_thresh::Float64, top_n::Int64)::AbstractArray{Int}

Find selected sites with distances between each other < median distance-dist_thresh*(median distance).
Replaces these sites with sites in the top_n ranks if the distance between these sites is greater.

# Arguments
- `pref_sites` : original n highest ranked sites selected for seeding or shading.
- `site_order` : current order of ranked sites in terms of numerical site ID.
- `dist` : Matrix of unique distances between sites.
- `min_dist` : minimum distance between sites for selected sites.
- `top_n` : number of top ranked sites to re-select from.

# Returns
- `prefsites` : new set of selected sites for seeding or shading.
"""
function distance_sorting(pref_sites::AbstractArray{Int}, s_order::Matrix{Union{Float64,Int64}}, dist::Array{Float64},
    min_dist::Float64, top_n::Int64, rankings::Matrix{Int64}, rank_col::Int64)::Tuple{Vector{Union{Float64,Int64}},Matrix{Int64}}
    # set-up
    n_sites = length(pref_sites)
    site_order = s_order[:, 1]

    # sites to select alternatives from
    alt_sites = setdiff(site_order, pref_sites)[1:min(top_n, length(site_order) - n_sites)]

    # find all selected sites closer than the min distance
    pref_dists = findall(dist[pref_sites, pref_sites] .< min_dist)
    # indices to replace
    inds_rep = sort(unique(reinterpret(Int64, pref_dists)))
    # number of sites to replace
    select_n = length(inds_rep)
    # indices to keep
    inds_keep = collect(1:length(pref_sites))
    inds_keep = setdiff(inds_keep, inds_rep)

    # storage for new set of sites
    rep_sites = pref_sites

    while (length(alt_sites) .>= select_n)
        rep_sites = [rep_sites[inds_keep[:]]; alt_sites[1:select_n]]

        # Find all sites within these highly ranked but unselected sites which are further apart
        alt_dists = dist[rep_sites, rep_sites] .> min_dist

        # Select from these sites those far enough away from all sites
        inds_keep = sum(alt_dists, dims=2) .== n_sites - 1

        # Keep sites that were far enough away last iteration
        inds_keep[1:end-select_n] .= true
        if length(inds_keep) == n_sites
            select_n = 0
            break
        else
            # remove checked alt_sites
            alt_sites = setdiff(alt_sites, alt_sites[1:select_n])
            select_n = sum(.!inds_keep)
        end
    end

    # If not all sites could be replaced, just use highest ranked remaining pref_sites
    if (select_n != 0) && !isempty(setdiff(pref_sites, rep_sites))
        rem_pref_sites = setdiff(pref_sites, rep_sites)
        rep_sites[end-select_n+1:end] .= rem_pref_sites[1:select_n]
    end

    new_site_order = setdiff(site_order, rep_sites)
    new_site_order = [rep_sites; new_site_order]
    s_order[:, 1] .= new_site_order
    # Match by site_id and assign rankings to log
    align_rankings!(rankings, s_order, rank_col)

    return rep_sites, rankings
end

"""
    order_ranking(S::Array{Float64, 2})

Uses simple summation as aggregation method for decision criteria.
Then orders sites from highest aggregate score to lowest.

# Arguments
- `S` : Decision matrix (seeding or shading)

# Returns
- `s_order` : nsites × 3 matrix with columns
    1. site ids
    2. calculated site rank score (higher values = higher ranked)
    3. site order id
"""
function order_ranking(S::Array{Float64,2})::Array{Union{Float64,Int64},2}
    n::Int64 = size(S, 1)
    s_order::Array = Union{Float64,Int64}[zeros(Int, n) zeros(Float64, n) zeros(Int, n)]

    # Simple ranking - add criteria weighted values for each sites
    # Third column is derived from the number of sites for situations where
    # a subset of sites are being investigated (and so using their site IDs
    # will be inappropriate)
    @views s_order[:, 1] .= Int.(S[:, 1])
    @views s_order[:, 2] .= sum(S[:, 2:end], dims=2)

    # Reorder ranks (highest to lowest)
    s_order .= sortslices(s_order, dims=1, by=x -> x[2], rev=true)

    @views s_order[:, 3] .= Int.(1:size(S, 1))

    return s_order
end


"""
    topsis(S::Array{Float64, 2})

Calculates ranks using the aggregation method of the TOPSIS MCDA algorithm.
Rank for a particular site is calculated as a ratio

    C = S_n/(S_p + S_n)

S_n = √{∑(criteria .- NIS)²}
    is the squareroot of the summed differences between the criteria for a site and the
    Negative Ideal Solution (NIS), or worst performing site in each criteria.
S_p  = √{∑(criteria .- NIS)²}
    is the squareroot of the summed differences between the criteria for a site and the
    Positive Ideal Solution (PIS), or best performing site in each criteria.

    Details of this aggregation method in, for example [1].

# References
1. Opricovic, Serafim & Tzeng, Gwo-Hshiung. (2004) European Journal of Operational Research.
    Vol. 156. pp. 445.
    https://doi.org/10.1016/S0377-2217(03)00020-1.

# Arguments
- `S` : Decision matrix (seeding or shading)

# Returns
- `s_order` :
    1. site ids
    2. calculated site rank score (higher values = higher ranked)
    3. site order id
"""
function topsis(S::Array{Float64,2})::Array{Union{Float64,Int64},2}

    # compute the set of positive ideal solutions for each criteria
    PIS = maximum(S[:, 2:end], dims=1)

    # compute the set of negative ideal solutions for each criteria
    NIS = minimum(S[:, 2:end], dims=1)

    # calculate separation distance from the ideal and non-ideal solutions
    S_p = sqrt.(sum((S[:, 2:end] .- PIS) .^ 2, dims=2))
    S_n = sqrt.(sum((S[:, 2:end] .- NIS) .^ 2, dims=2))

    # final ranking measure of relative closeness C
    C = S_n ./ (S_p + S_n)

    # Create matrix where rank ids are integers (for use as indexers later)
    # Third column is derived from the number of sites for situations where
    # a subset of sites are being investigated (and so using their site IDs
    # will be inappropriate)
    s_order = Union{Float64,Int64}[Int.(S[:, 1]) C 1:size(S, 1)]

    # Reorder ranks (highest to lowest)
    s_order .= sortslices(s_order, dims=1, by=x -> x[2], rev=true)
    @views s_order[:, 3] .= Int.(1:size(S, 1))

    return s_order
end


"""
    vikor(S; v=0.5)

Calculates ranks using the aggregation method of the VIKOR MCDA algorithm.
Rank for a particular site is calculated as a linear combination of ratios,
weighted by v:
    Q = v(Sr - S_h) / (S_s - S_h) + (1 - v)(R - R_h) / (R_s - R_h)

where
- Sr = ∑(PIS-criteria) for each site, summed over criteria.
- R = max(PIS-criteria) for each site, with the max over criteria.
- S_h = min(∑(PIS-criteria)) over sites, the minimum summed distance from
    the positive ideal solution.
- S_s = max(∑(PIS-criteria)) over sites, maximum summed distance from
    the positive ideal solution.
- R_h = min(max(PIS-criteria)) over sites, the minimum max distance from
    the positive ideal solution.
- R_s = max(max(PIS-criteria)) over sites, the maximum max distance from
    the positive ideal solution.
- v = weighting, representing different decision-making strategies,
    or level of compromise between utility (overall performance)
    and regret (risk of performing very badly in one criteria despite
    exceptional performance in others)
    - v = 0.5 is consensus
    - v < 0.5 is minimal regret
    - v > 0.5 is max group utility (majority rules)

Details of this aggregation method in, for example [1]

# References
1. Alidrisi H. (2021) Journal of Risk and Financial Management.
    Vol. 14. No. 6. pp. 271.
    https://doi.org/10.3390/jrfm14060271

# Arguments
- `S` : Matrix
- `v` : Real

# Returns
- `s_order` :
    1. site ids
    2. calculated site rank score (higher values = higher ranked)
    3. site order id
"""
function vikor(S::Array{Float64,2}; v::Float64=0.5)::Array{Union{Float64,Int64},2}

    F_s = maximum(S[:, 2:end])

    # Compute utility of the majority Sr (Manhatten Distance)
    # Compute individual regret R (Chebyshev distance)
    sr_arg = (F_s .- S[:, 2:end])
    Sr = [S[:, 1] sum(sr_arg, dims=2)]
    R = [S[:, 1] maximum(sr_arg, dims=2)]

    # Compute the VIKOR compromise Q
    S_s, S_h = maximum(Sr[:, 2]), minimum(Sr[:, 2])
    R_s, R_h = maximum(R[:, 2]), minimum(R[:, 2])
    Q = @. v * (Sr[:, 2] - S_h) / (S_s - S_h) + (1 - v) * (R[:, 2] - R_h) / (R_s - R_h)
    Q .= 1.0 .- Q  # Invert rankings so higher values = higher rank

    # Create matrix where rank ids are integers (for use as indexers later)
    # Third column is necessary as a subset of sites will not match their Index IDs.
    s_order = Union{Float64,Int64}[Int.(S[:, 1]) Q zeros(size(Q, 1))]

    # sort Q by rank score in descending order
    s_order .= sortslices(s_order, dims=1, by=x -> x[2], rev=true)
    @views s_order[:, 3] .= Int.(1:size(S, 1))

    return s_order
end

"""
    run_site_selection(domain::Domain, scenarios::DataFrame, sum_cover::AbstractArray, area_to_seed::Float64, time_step::Int64)

Perform site selection for a given domain for multiple scenarios defined in a dataframe.

# Arguments
- `domain` : ADRIA Domain type, indicating geographical domain to perform site selection over.
- `scenarios` : DataFrame of criteria weightings and thresholds for each scenario.
- `sum_cover` : array of size (number of scenarios * number of sites) containing the summed coral cover for each site selection scenario.
- `area_to_seed` : area of coral to be seeded at each time step in km^2
- `timestep` : time step at which seeding and/or shading is being undertaken.

# Returns
- `ranks_store` : number of scenarios * sites * 3 (last dimension indicates: site_id, seed rank, shade rank)
    containing ranks for each scenario run.
"""
function run_site_selection(dom::Domain, scenarios::DataFrame, sum_cover::AbstractArray, area_to_seed::Float64, timestep::Int64;
    target_seed_sites=nothing, target_shade_sites=nothing)
    ranks_store = NamedDimsArray(
        zeros(nrow(scenarios), length(dom.site_ids), 3),
        scenarios=1:nrow(scenarios),
        sites=dom.site_ids,
        ranks=["site_id", "seed_rank", "shade_rank"],
    )

    dhw_scens = dom.dhw_scens
    wave_scens = dom.wave_scens

    # Pre-calculate maximum depth to consider
    scenarios[:, "max_depth"] .= scenarios.depth_min .+ scenarios.depth_offset
    target_site_ids = Int64[]
    if !isnothing(target_seed_sites)
        append!(target_site_ids, target_seed_sites)
    end

    if !isnothing(target_shade_sites)
        append!(target_site_ids, target_shade_sites)
    end

    for (cover_ind, scen) in enumerate(eachrow(scenarios))
        depth_criteria = (dom.site_data.depth_med .<= scen.max_depth) .& (dom.site_data.depth_med .>= scen.depth_min)
        depth_priority = findall(depth_criteria)

        considered_sites = target_site_ids[findall(in(depth_priority), target_site_ids)]

        ranks_store(scenarios=cover_ind, sites=dom.site_ids[considered_sites]) .= site_selection(
            dom,
            scen,
            mean(wave_scens, dims=(:timesteps, :scenarios)) .+ var(wave_scens, dims=(:timesteps, :scenarios)),
            mean(dhw_scens, dims=(:timesteps, :scenarios)) .+ var(dhw_scens, dims=(:timesteps, :scenarios)),
            considered_sites,
            sum_cover[cover_ind, :],
            area_to_seed
        )
    end

    return ranks_store
end

"""
    site_selection(domain::Domain, scenario::DataFrameRow{DataFrame,DataFrames.Index}, w_scens::NamedDimsArray, dhw_scens::NamedDimsArray, sum_cover::AbstractArray, area_to_seed::Float64)

Perform site selection using a chosen mcda aggregation method, domain, initial cover, criteria weightings and thresholds.

# Arguments
- `scenario` : contains criteria weightings and thresholds for a single scenario.
- `mcda_vars` : site selection criteria and weightings structure
- `w_scens` : array of length nsites containing wave scenario.
- `dhw_scens` : array of length nsites containing dhw scenario.
- `sum_cover` : summed cover (over species) for single scenario being run, for each site.
- `area_to_seed` : area of coral to be seeded at each time step in km^2

# Returns
- `ranks` : n_reps * sites * 3 (last dimension indicates: site_id, seeding rank, shading rank)
    containing ranks for single scenario.
"""
function site_selection(domain::Domain, scenario::DataFrameRow, w_scens::NamedDimsArray, dhw_scens::NamedDimsArray,
    site_ids::AbstractArray, sum_cover::AbstractArray, area_to_seed::Float64)::Matrix{Int64}

    mcda_vars = DMCDA_vars(domain, scenario, site_ids, sum_cover, area_to_seed, w_scens, dhw_scens)
    n_sites = length(mcda_vars.site_ids)

    # site_id, seeding rank, shading rank
    rankingsin = [mcda_vars.site_ids zeros(Int64, (n_sites, 1)) zeros(Int64, (n_sites, 1))]

    prefseedsites::Matrix{Int64} = zeros(Int64, (1, mcda_vars.n_site_int))
    prefshadesites::Matrix{Int64} = zeros(Int64, (1, mcda_vars.n_site_int))

    (_, _, ranks) = guided_site_selection(mcda_vars, scenario.guided, true, true, prefseedsites, prefshadesites, rankingsin)

    return ranks
end



"""
    unguided_site_selection(prefseedsites, prefshadesites, seed_years, shade_years, n_site_int, max_cover)

Randomly select seed/shade site locations for the given year, constraining to sites with max. carrying capacity > 0.
Here, `max_cover` represents the max. carrying capacity for each site (the `k` value).

# Arguments
- `prefseedsites` : Previously selected sites
- `seed_years` : bool, indicating whether to seed this year or not
- `shade_years` : bool, indicating whether to shade this year or not
- `n_site_int` : int, number of sites to intervene on
- `available_space` : vector/matrix : space available at each site (`k` value)
- `depth` : vector of site ids found to be within desired depth range
"""
function unguided_site_selection(prefseedsites, prefshadesites, seed_years, shade_years, n_site_int, available_space, depth)
    # Unguided deployment, seed/shade corals anywhere so long as available_space > 0.1
    # Only sites that have available space are considered, otherwise a zero-division error may occur later on.

    # Select sites (without replacement to avoid duplicate sites)
    candidate_sites = depth[(available_space.>0.0)[depth]]  # Filter down to site ids to be considered
    num_sites = length(candidate_sites)
    s_n_site_int = num_sites < n_site_int ? num_sites : n_site_int

    if seed_years
        prefseedsites = zeros(Int64, n_site_int)
        prefseedsites[1:s_n_site_int] .= StatsBase.sample(candidate_sites, s_n_site_int; replace=false)
    end

    if shade_years
        prefshadesites = zeros(Int64, n_site_int)
        prefshadesites[1:s_n_site_int] .= StatsBase.sample(candidate_sites, s_n_site_int; replace=false)
    end

    return prefseedsites[prefseedsites.>0], prefshadesites[prefshadesites.>0]
end
