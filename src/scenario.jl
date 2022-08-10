"""Scenario running functions"""


"""
    setup_cache(domain::Domain)::NamedTuple

Establish tuple of matrices/vectors for use as reusable data stores to avoid repeated memory allocations.
"""

using Infiltrator

function setup_cache(domain::Domain)::NamedTuple

    # sim constants
    n_sites::Int64 = domain.coral_growth.n_sites
    n_species::Int64 = domain.coral_growth.n_species
    n_groups::Int64 = domain.coral_growth.n_groups

    # Strip names from NamedArrays
    init_cov = Matrix{Float64}(domain.init_coral_cover)

    cache = (
        LPs = zeros(n_groups, n_sites),
        fec_all = similar(init_cov, Float64),
        fec_scope = zeros(n_groups, n_sites),
        prop_loss = zeros(n_species, n_sites),
        Sbl = zeros(n_species, n_sites),
        dhw_step = zeros(n_sites),
        init_cov = init_cov,
        cov_tmp = similar(init_cov),
        site_area = Array{Float64}(domain.site_data.area'),
        TP_data = Array{Float64, 2}(domain.TP_data)
    )

    return cache
end


"""
    run_scenarios(param_df::DataFrame, domain::Domain; reps::Int64=0)

Run scenarios defined by the parameter table storing results to disk.
Scenarios are run in parallel where the number of scenarios > 16.

# Notes
Returned `domain` holds scenario invoke time used as unique result set identifier.

# Arguments
- param_df : DataFrame of scenarios to run
- domain : Domain, to run scenarios with
- reps : Environmental scenario repeats. If 0 (the default), loads the user-specified value from config.

# Returns
domain
"""
function run_scenarios(param_df::DataFrame, domain::Domain; reps::Int64=0)::Domain
    has_setup()

    if reps <= 0
        reps = parse(Int, ENV["ADRIA_reps"])
    end

    domain, data_store = ADRIA.setup_result_store!(domain, param_df, reps)
    cache = setup_cache(domain)

    func = (dfx) -> run_scenario(dfx, domain, reps, data_store, cache)

    # Batch run scenarios
    if nrow(param_df) > 64
        @eval @everywhere using ADRIA

        @showprogress "Running..." 4 pmap(func, enumerate(eachrow(param_df)))
    else
        @showprogress "Running..." 1 map(func, enumerate(eachrow(param_df)))
    end

    return domain
end


"""
    run_scenarios(scen::Tuple{Int, DataFrameRow}, domain::Domain, reps::Int64, data_store::NamedTuple)

Run individual scenarios for a given domain.

Stores results on disk in Zarr format at pre-configured location.

# Notes
Only the mean site rankings over all environmental scenarios are kept
"""
function run_scenario(scen::Tuple{Int, DataFrameRow}, domain::Domain, reps::Int64, data_store::NamedTuple, cache::NamedTuple)
    # Update model with values in given DF row
    update_params!(domain, scen[2])

    # TODO: Modify all scenario constants here to avoid repeated allocations
    @set! domain.coral_growth.ode_p.P = (domain.site_data.k::Vector{Float64} / 100.0)  # Max possible cover at site
    @set! domain.coral_growth.ode_p.comp = domain.sim_constants.comp::Float64  # competition rate between two mature coral groups

    run_scenario(domain; idx=scen[1], reps=reps, data_store=data_store, cache=cache)
end
function run_scenario(scen::Tuple{Int, DataFrameRow}, domain::Domain, reps::Int64, data_store::NamedTuple)
    run_scenario(scen, domain, reps, data_store, setup_cache(domain))
end


"""
    proportional_adjustment!(Yout::AbstractArray{<:Real}, Ycover::AbstractArray{<:Real}, max_cover::AbstractArray{<:Real}, tstep::Int64)

Helper method to proportionally adjust coral cover.
Modifies arrays in-place.

# Arguments
- Yout : Coral cover result set
- Ycover : Temporary cache matrix, avoids memory allocations
- max_cover : maximum possible coral cover for each site
- tstep : current time step
"""
function proportional_adjustment!(Yout::AbstractArray{<:Real}, Ycover::AbstractArray{<:Real}, max_cover::AbstractArray{<:Real}, tstep::Int64)
    # Proportionally adjust initial covers
    @views Ycover .= vec(sum(Yout[tstep, :, :], dims=1))
    if any(Ycover .> max_cover)
        exceeded::Vector{Int32} = findall(Ycover .> vec(max_cover))

        @views Yout[tstep, :, exceeded] .= (Yout[tstep, :, exceeded] ./ Ycover[exceeded]') .* max_cover[exceeded]'
    end
end


"""
    run_scenario(domain::Domain; reps=1, data_store::NamedTuple, cache::NamedTuple)::NamedTuple

Convenience function to directly run a scenario for a Domain with pre-set values.

Stores results on disk in Zarr format at pre-configured location.

# Notes
Logs of site ranks only store the mean site rankings over all environmental scenarios.
This is to reduce the volume of data stored.
"""
function run_scenario(domain::Domain; idx::Int=1, reps::Int=1, data_store::NamedTuple, cache::NamedTuple)
    tf = domain.sim_constants.tf

    # Extract non-coral parameters
    df = DataFrame(domain.model)
    not_coral_params = df[!, :component] .!== Coral
    param_set = NamedTuple{tuple(df[not_coral_params, :fieldname]...)}(df[not_coral_params, :val])

    # Expand coral model to include its specifications across all taxa/species/groups
    coral_params = to_spec(component_params(domain.model, Coral))

    # Pass in environmental layer data stripped of named dimensions.
    all_dhws = Array{Float64}(domain.dhw_scens[1:tf, :, 1:reps])
    all_waves = Array{Float64}(domain.wave_scens[1:tf, :, 1:reps])

    result_set = Array{NamedTuple}(repeat([(empty=0,)], reps))
    @inbounds for i::Int in 1:reps
        result_set[i] = run_scenario(domain, param_set, coral_params, domain.sim_constants, domain.site_data,
                                     domain.coral_growth.ode_p,
                                     all_dhws[:, :, i], all_waves[1:tf, :, i], cache)
    end

    # Capture results to disk
    # Set values below threshold to 0 to save space
    threshold = parse(Float32, ENV["ADRIA_THRESHOLD"])
    tmp_site_ranks = zeros(Float32, tf, nrow(domain.site_data), 2, reps)

    for (k, v) in pairs(data_store)
        if !isnothing(v)
            c_dim = ndims(getfield(result_set[1], k)) + 1
            vals::Array{Float32} = convert(Array{Float32}, cat(Array{Float32}[getfield(r, k) for r in result_set]..., dims=c_dim))

            vals[vals .< threshold] .= 0.0

            if k == :raw || k == :seed_log
                v[:, :, :, 1:reps, idx] .= vals
            elseif k == :site_ranks
                tmp_site_ranks[:, :, :, 1:reps] .= vals
            else
                v[:, :, 1:reps, idx] .= vals
            end
        end
    end

    if !isnothing(data_store.site_ranks)
        # Squash site ranks down to average rankings over environmental repeats
        data_store.site_ranks[:, :, :, idx] = dropdims(mean(tmp_site_ranks, dims=4), dims=4)
    end
end


"""
    run_scenario(param_df, domain)

Run a single scenario and return results.
"""
function run_scenario(param_df::DataFrameRow, domain::Domain; rep_id::Int=1)::NamedTuple
    has_setup()

    # Update model with values in given DF row
    update_params!(domain, param_df)

    param_set = NamedTuple{domain.model[:fieldname]}(domain.model[:val])

    # Expand coral model to include its specifications across all taxa/species/groups
    coral_params = to_spec(component_params(domain.model, Coral))

    cache = setup_cache(domain)
    return run_scenario(domain, param_set, coral_params, domain.sim_constants, domain.site_data,
                        domain.coral_growth.ode_p,
                        Matrix{Float64}(domain.dhw_scens[1:tf, :, rep_id]), 
                        Matrix{Float64}(domain.wave_scens[1:tf, :, rep_id]), cache)
end


"""
    run_scenario(domain, param_set, corals, sim_params, site_data, p::NamedTuple,
                 dhw_scen::Array, wave_scen::Array, cache::NamedTuple)::NamedTuple

Core scenario running function.

# Notes
Only the mean site rankings are kept
"""
function run_scenario(domain::Domain, param_set::NamedTuple, corals::DataFrame, sim_params::SimConstants, site_data::DataFrame,
    p::NamedTuple, dhw_scen::Matrix{Float64},
    wave_scen::Matrix{Float64}, cache::NamedTuple)::NamedTuple

    ### TODO: All cached arrays/values to be moved to outer function and passed in
    # to reduce overall allocations (e.g., sim constants don't change across all scenarios)

    tspan::Tuple = (0.0, 1.0)
    solver::RK4 = RK4()

    MCDA_approach::Int64 = param_set.guided

    # sim constants
    n_sites::Int64 = domain.coral_growth.n_sites
    nsiteint::Int64 = sim_params.nsiteint
    tf::Int64 = sim_params.tf
    n_species::Int64 = domain.coral_growth.n_species
    n_groups::Int64 = domain.coral_growth.n_groups

    # years to start seeding/shading
    seed_start_year::Int64 = param_set.seed_year_start
    shade_start_year::Int64 = param_set.shade_year_start

    seed_TA_vol::Int64 = param_set.seed_TA  # tabular Acropora size class 2, per year per species per cluster
    seed_CA_vol::Int64 = param_set.seed_CA  # corymbose Acropora size class 2, per year per species per cluster
    fogging::Real = param_set.fogging  # percent reduction in bleaching mortality through fogging
    srm::Real = param_set.SRM  # DHW equivalents reduced by some shading mechanism
    seed_years::Int64 = param_set.seed_years  # number of years to seed
    shade_years::Int64 = param_set.shade_years  # number of years to shade

    # Gompertz shape parameters for bleaching
    neg_e_p1::Real = -sim_params.gompertz_p1
    neg_e_p2::Real = -sim_params.gompertz_p2

    ### END TODO

    # site_area::Array{Float64,2} = site_data.area'
    site_area = cache.site_area

    fec_params::Vector{Float64} = corals.fecundity
    potential_settler_cover::Float64 = (sim_params.max_settler_density *
                                        sim_params.basal_area_per_settler *
                                        sim_params.density_ratio_of_settlers_to_larvae)

    # Caches
    # TP_data::Array{Float64,2} = Matrix(domain.TP_data)
    TP_data = cache.TP_data
    # LPs::Array{Float64,2} = zeros(n_groups, n_sites)
    # fec_all::Array{Float64,2} = similar(init_cov, Float64)
    # fec_scope::Array{Float64,2} = zeros(n_groups, n_sites)
    # prop_loss::Array{Float64,2} = zeros(n_species, n_sites)
    # Sbl::Array{Float64,2} = zeros(n_species, n_sites)
    # dhw_step::Vector{Float64} = zeros(n_sites)
    LPs = cache.LPs[:, :]
    fec_all = cache.fec_all[:, :]
    fec_scope = cache.fec_scope[:, :]
    prop_loss = cache.prop_loss[:, :]
    Sbl = cache.Sbl[:, :]
    dhw_step = cache.dhw_step[:]
    cov_tmp = cache.cov_tmp[:, :]

    Yout::Array{Float64,3} = zeros(tf, n_species, n_sites)
    Yout[1, :, :] .= @view cache.init_cov[:, :]
    # cov_tmp::Array{Float64,2} = similar(init_cov, Float64)
    Ycover::Vector{Float64} = zeros(n_sites)

    site_ranks = SparseArray(zeros(tf, n_sites, 2)) # log seeding/fogging/shading ranks
    Yshade = SparseArray(spzeros(tf, n_sites))
    Yfog = SparseArray(spzeros(tf, n_sites))
    Yseed = SparseArray(zeros(tf, 2, n_sites))  # 2 = the two enhanced coral types
    # site_ranks = @view cache.site_ranks[:, :]
    # Yshade = @view cache.Yshade[:, :]
    # Yfog = @view cache.Yfog[:, :]
    # Yseed = @view cache.Yseed[:, :]

    # Intervention strategy: 0 is random, > 0 is guided
    is_guided = param_set.guided > 0

    # Years at which to reassess seeding site selection
    seed_decision_years = repeat([false], tf)
    shade_decision_years = repeat([false], tf)

    if param_set.seed_freq > 0
        max_consider = min(seed_start_year+seed_years-1, tf)
        seed_decision_years[seed_start_year:param_set.seed_freq:max_consider] .= true
    else
        # Start at year 2 or the given specified seed start year
        seed_decision_years[max(seed_start_year, 2)] = true
    end

    if param_set.shade_freq > 0
        max_consider = min(shade_start_year+shade_years-1, tf)
        shade_decision_years[shade_start_year:param_set.shade_freq:max_consider] .= true
    else
        # Start at year 2 or the given specified shade start year
        shade_decision_years[max(shade_start_year, 2)] = true
    end

    prefseedsites::Vector{Int64} = zeros(Int, nsiteint)
    prefshadesites::Vector{Int64} = zeros(Int, nsiteint)

    # Max coral cover at each site. Divided by 100 to convert to proportion
    max_cover = site_data.k / 100.0

    # Proportionally adjust initial cover (handles inappropriate initial conditions)
    proportional_adjustment!(Yout, Ycover, max_cover, 1)

    if is_guided
        ## Weights for connectivity , waves (ww), high cover (whc) and low
        wtwaves = param_set.wave_stress # weight of wave damage in MCDA
        wtheat = param_set.heat_stress # weight of heat damage in MCDA
        wtconshade = param_set.shade_connectivity # weight of connectivity for shading in MCDA
        wtconseed = param_set.seed_connectivity # weight of connectivity for seeding in MCDA
        wthicover = param_set.coral_cover_high # weight of high coral cover in MCDA (high cover gives preference for seeding corals but high for SRM)
        wtlocover = param_set.coral_cover_low # weight of low coral cover in MCDA (low cover gives preference for seeding corals but high for SRM)
        wtpredecseed = param_set.seed_priority # weight for the importance of seeding sites that are predecessors of priority reefs
        wtpredecshade = param_set.shade_priority # weight for the importance of shading sites that are predecessors of priority reefs
        risktol = param_set.deployed_coral_risk_tol # risk tolerance

        # Defaults to considering all sites if depth cannot be considered.
        depth_priority = collect(1:nrow(site_data))

        # Filter out sites outside of desired depth range
        if .!all(site_data.sitedepth .== 0)
            max_depth::Float64 = param_set.depth_min + param_set.depth_offset
            depth_criteria::BitArray{1} = (site_data.sitedepth .>= -max_depth) .& (site_data.sitedepth .<= -param_set.depth_min)

            # TODO: Include this change in MATLAB version as well
            if any(depth_criteria .> 0)
                # If sites can be filtered based on depth, do so. Otherwise if no sites can be filtered, remove depth as a criterion.
                depth_priority = depth_priority[depth_criteria]
            else
                @warn "No sites within provided depth range of $(param_set.depth_min) - $(max_depth) meters. Considering all sites."
            end
        end

        # pre-allocate rankings
        rankings = [depth_priority zeros(Int, length(depth_priority)) zeros(Int, length(depth_priority))]
        
        # Prep site selection
        mcda_vars = DMCDA_vars(
            depth_priority,
            nsiteint,
            sim_params.prioritysites,
            domain.strongpred,
            domain.conn_ranks,
            zeros(n_species, n_sites),  # dam prob
            dhw_scen,  # heatstressprob
            Yout[1, :, :],  # sumcover
            max_cover,
            site_area,
            risktol,
            wtconseed,
            wtconshade,
            wtwaves,
            wtheat,
            wthicover,
            wtlocover,
            wtpredecseed,
            wtpredecshade
        )
    else
        # TODO: More robust way of getting intervention/criteria values
        rnd_seed_val = floor(Int, sum([copy(getindex(param_set, i)) for i in 1:24]))
        Random.seed!(rnd_seed_val)
    end

    # logs for seeding, shading and cooling
    # nprefseed = zeros(Int, [tf])
    # nprefshade = zeros(Int, [tf])

    # Define constant table location for seed values
    # Seed1 = Tabular Acropora Enhanced (taxa 1, size class 2)
    # Seed2 = Corymbose Acropora Enhanced (taxa 3, size class 2)
    tabular_enhanced::BitArray = corals.taxa_id .== 1
    corymbose_enhanced::BitArray = corals.taxa_id .== 3
    target_class_id::BitArray = corals.class_id .== 2
    seed_size_class1::Int64 = first(findall(tabular_enhanced .& target_class_id))
    seed_size_class2::Int64 = first(findall(corymbose_enhanced .& target_class_id))

    #### End coral constants

    ## Update ecological parameters based on intervention option
    # Set up assisted adaptation values
    a_adapt = zeros(n_species)

    # assign level of assisted coral adaptation
    a_adapt[tabular_enhanced] .= param_set.a_adapt
    a_adapt[corymbose_enhanced] .= param_set.a_adapt
    n_adapt = param_set.n_adapt  # Level of natural coral adaptation

    # level of added natural coral adaptation
    n_adapt = param_set.n_adapt  # natad = coral_params.natad + interv.Natad;
    bleach_resist = corals.bleach_resist

    ## Extract other parameters
    LPdhwcoeff = sim_params.LPdhwcoeff # shape parameters relating dhw affecting cover to larval production
    DHWmaxtot = sim_params.DHWmaxtot # max assumed DHW for all scenarios.  Will be obsolete when we move to new, shared inputs for DHW projections
    LPDprm2 = sim_params.LPDprm2 # parameter offsetting LPD curve

    # Wave stress
    mwaves::Array{Float64,3} = zeros(tf, n_species, n_sites)
    wavemort90::Vector{Float64} = corals.wavemort90::Vector{Float64}  # 90th percentile wave mortality

    @inbounds for sp::Int64 in 1:n_species
        @views mwaves[:, sp, :] .= wavemort90[sp] .* wave_scen[:, :, :]
    end

    mwaves[mwaves .< 0.0] .= 0.0
    mwaves[mwaves .> 1.0] .= 1.0

    Sw_t = 1.0 .- mwaves

    # Flag indicating whether to seed or not to seed
    seed_corals = (seed_TA_vol > 0) || (seed_CA_vol > 0)

    # extract colony areas for sites selected and convert to m^2
    col_area_seed_TA = corals.colony_area_cm2[seed_size_class1] / 10^4
    col_area_seed_CA = corals.colony_area_cm2[seed_size_class2] / 10^4

    growth::ODEProblem = ODEProblem{true,false}(growthODE, cov_tmp, tspan, p)
    @inbounds for tstep::Int64 in 2:tf
        p_step = tstep - 1
        @views cov_tmp[:, :] .= Yout[p_step, :, :]

        LPs .= larval_production(tstep, a_adapt, n_adapt, dhw_scen[p_step, :],
                                 LPdhwcoeff, DHWmaxtot, LPDprm2, n_groups)

        # Calculates scope for coral fedundity for each size class and at
        # each site. Now using coral fecundity per m2 in 'coralSpec()'
        fecundity_scope!(fec_scope, fec_all, fec_params, cov_tmp, site_area)

        # adjusting absolute recruitment at each site by dividing by the area
        @views p.rec[:, :] .= (potential_settler_cover .* ((fec_scope .* LPs) * TP_data)) ./ site_area
        
        @views dhw_step .= dhw_scen[tstep, :]  # subset of DHW for given timestep

        in_shade_years = (shade_start_year <= tstep) && (tstep <= (shade_start_year + shade_years - 1))
        in_seed_years = ((seed_start_year <= tstep) && (tstep <= (seed_start_year + seed_years - 1)))
        if is_guided
            # Update dMCDA values
            mcda_vars.damprob .= @view mwaves[tstep, :, :]
            #mcda_vars.heatstressprob .= dhw_step

            mcda_vars.sumcover .= sum(cov_tmp, dims=1)  # dims: nsites * 1

            (prefseedsites, prefshadesites, nprefseedsites, nprefshadesites, rankings) = dMCDA(mcda_vars, MCDA_approach,
                seed_decision_years[tstep], shade_decision_years[tstep],
                prefseedsites, prefshadesites, rankings)

            # nprefseed[tstep] = nprefseedsites    # number of preferred seeding sites
            # nprefshade[tstep] = nprefshadesites  # number of preferred shading sites

            # Log site ranks
            # First col only holds site ids so skip (with 2:end)
            site_ranks[tstep, rankings[:, 1], :] = rankings[:, 2:end]
        else
            # Unguided
            if seed_decision_years[tstep]
                # Unguided deployment, seed/shade corals anywhere
                prefseedsites = rand(1:n_sites, nsiteint)
            end

            if shade_decision_years[tstep]
                prefshadesites = rand(1:n_sites, nsiteint)
            end
        end

        has_shade_sites = !all(prefshadesites .== 0)
        has_seed_sites = !all(prefseedsites .== 0)
        if (srm > 0) && in_shade_years
            Yshade[tstep, :] .= srm

            # Apply reduction in DHW due to shading
            adjusted_dhw::Vector{Float64} = max.(0.0, dhw_step .- Yshade[tstep, :])
        else
            adjusted_dhw = dhw_step
        end

        if (fogging > 0.0) && in_shade_years && (has_seed_sites || has_shade_sites)
            if has_seed_sites
                # Always fog where sites are selected if possible
                site_locs::Vector{Int64} = prefseedsites
            elseif has_shade_sites
                # Otherwise, if no sites are selected, fog selected shade sites
                site_locs = prefshadesites
            end

            adjusted_dhw[site_locs] = adjusted_dhw[site_locs] .* (1.0 - fogging)
            Yfog[tstep, site_locs] .= fogging
        end

        # Calculate and apply bleaching mortality
        bleaching_mortality!(Sbl, tstep, neg_e_p1,
            neg_e_p2, a_adapt, n_adapt,
            bleach_resist, adjusted_dhw)

        # proportional loss + proportional recruitment
        @views prop_loss = Sbl[:, :] .* Sw_t[p_step, :, :]
        @views cov_tmp = cov_tmp[:, :] .* prop_loss[:, :]

        # Apply seeding
        if seed_corals && in_seed_years && has_seed_sites
            # extract site area for sites selected and scale by available space for populations (k/100)
            site_area_seed = site_area[prefseedsites] .* max_cover[prefseedsites]

            scaled_seed_TA = (((seed_TA_vol / nsiteint) * col_area_seed_TA) ./ site_area_seed)
            scaled_seed_CA = (((seed_CA_vol / nsiteint) * col_area_seed_CA) ./ site_area_seed)

            # Seed each site with the value indicated with seed1/seed2
            @views cov_tmp[seed_size_class1, prefseedsites] .= cov_tmp[seed_size_class1, prefseedsites] .+ scaled_seed_TA  # seed Enhanced Tabular Acropora
            @views cov_tmp[seed_size_class2, prefseedsites] .= cov_tmp[seed_size_class2, prefseedsites] .+ scaled_seed_CA  # seed Enhanced Corymbose Acropora

            # Log seed values/sites
            @views Yseed[tstep, 1, prefseedsites] = scaled_seed_TA  # log site as seeded with Enhanced Tabular Acropora
            @views Yseed[tstep, 2, prefseedsites] = scaled_seed_CA  # log site as seeded with Enhanced Corymbose Acropora
        end

        growth.u0[:, :] .= @views cov_tmp[:, :] .* prop_loss[:, :]  # update initial condition
        sol::ODESolution = solve(growth, solver, save_everystep=false, save_start=false, 
                                 alg_hints=[:nonstiff], abstol=1e-8, reltol=1e-7)
        Yout[tstep, :, :] .= sol.u[end]

        # growth::ODEProblem = ODEProblem{true,false}(growthODE, cov_tmp .* prop_loss[:, :], tspan, p)
        # sol::ODESolution = solve(growth, solver, abstol=1e-7, reltol=1e-4, save_everystep=false, save_start=false, alg_hints=[:nonstiff])
        # Yout[tstep, :, :] .= sol.u[end]

        # Using the last step from ODE above, proportionally adjust site coral cover
        # if any are above the maximum possible (i.e., the site `k` value)
        proportional_adjustment!(Yout, Ycover, max_cover, tstep)
    end

    # avoid placing importance on sites that were not considered
    # (lower values are higher importance)
    site_ranks[site_ranks .== 0.0] .= n_sites + 1

    return (raw=Yout, seed_log=Yseed, fog_log=Yfog, shade_log=Yshade, site_ranks=site_ranks)
end
