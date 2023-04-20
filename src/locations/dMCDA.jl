"""Objects and methods for Dynamic Multi-Criteria Decision Analysis/Making"""

using StatsBase
using Distances
using Combinatorics
using JMcDM
using ADRIA: order_ranking, mcda_vikor, mcda_topsis


global mcda_methods = [
    order_ranking,
    mcda_vikor,
    mcda_topsis,
    [ArasMethod(), true],
    [CocosoMethod(), true],
    [CodasMethod(), true],
    [CoprasMethod(), false],
    [EdasMethod(), true],
    [GreyMethod(), true],
    [MabacMethod(), true],
    [MaircaMethod(), false],
    [MarcosMethod(), true],
    [MooraMethod(), true],
    #[MoosraMethod(), true],
    [PIVMethod(), true],
    [PSIMethod(), true],
    [ROVMethod(), true],
    [SawMethod(), true],
    [TopsisMethod(), true],
    [VikorMethod(), false],
    [WPMMethod(), true],
    [WaspasMethod(), true]
]

"""
    create_criteria_store(location_ids::AbstractArray, criteria::NamedTuple) 

    Constructs the criteria NamedDimsArray for performing location selection. 
    This is used to construct decision matrices for the mcda methods.

# Arguments
- `location_ids` : location ids as integers.
- `criteria` : NamedTuple of vectors of length nlocations containing criteria values to 
be used to construct mcda matrices. Keys should correspond to weight names and begin with "iv__".
Can also be entered as named varargs.
E.g. the criteria for heat stress will be iv__heat_stress and it's weight will be iv__heat_stress__seed_shade,
indicating it is used for seeding and shading.
"""
function create_criteria_store(location_ids::AbstractArray; criteria...)
    return create_criteria_store(location_ids, criteria)
end
function create_criteria_store(location_ids::AbstractArray, criteria::NamedTuple)
    criteria_matrix = zeros(length(location_ids), length(criteria))

    for (ind, crit_key) in enumerate(keys(criteria))
        criteria_matrix[:, ind] .= criteria[crit_key][location_ids]
    end
    return NamedDimsArray(criteria_matrix, locations=location_ids, criteria=collect(keys(criteria)))

end

"""
    create_tolerances_store(tolerances::NamedTuple)  

    Constructs the tolerances NamedDimsArray which is used to filter the decision matrix.

# Arguments
- `tolerances` : NamedTuple with format (criteria_name1=(operation,value),criteria_name2=(operation,value),...)
where operation is < or > and value is the tolerance value.

"""
function create_tolerances_store(tolerances::NamedTuple)
    tol_store = [x -> tolerances[tol_key][1](x, tolerances[tol_key][2]) for tol_key in keys(tolerances)]
    return NamedDimsArray(tol_store, criteria=collect(keys(tolerances)))
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
    align_rankings!(rankings::Array, l_order::Matrix, col::Int64)::Nothing

Align a vector of location rankings to match the indicated order in `l_order`.
"""
function align_rankings!(rankings::Array, l_order::Matrix)::Nothing
    # Fill target ranking column
    for (i, location_id) in enumerate(l_order[:, 1])
        rankings[rankings[:, 1].==location_id, 2] .= l_order[i, 3]
    end

    return
end

"""
    rank_locations!(S, weights, rankings, n_location_int, rank_col)
    rank_seed_locations!(S, weights, rankings, n_location_int)
    rank_shade_locations!(S, weights, rankings, n_location_int)

# Arguments
- `S` : Matrix, Site preference values
- `weights` : weights to apply
- `rankings` : vector of location ranks to update
- `n_location_int` : number of locations to select for interventions
- `rank_col` : column to fill with rankings (2 for seed, 3 for shade)

# Returns
- `preflocations` : locations in order of their rankings
"""
function rank_locations!(S, weights, rankings, n_location_int, location_ids, mcda_func)::Tuple{Vector{Int64},Matrix{Union{Float64,Int64}}}
    # Filter out all non-preferred locations
    selector = vec(.!all(S .== 0, dims=1))

    # weights in order of: in_conn, out_conn, wave, heat, predecessors, low cover
    weights = weights[selector]
    S = S[:, selector]

    l_order = retrieve_ranks(S, weights, mcda_func, location_ids)

    last_idx = min(n_location_int, size(l_order, 1))
    preflocations = Int.(l_order[1:last_idx, 1])

    # Match by location_id and assign rankings to log
    align_rankings!(rankings, l_order)

    return preflocations, l_order
end

"""
    filter_decision_matrix(criteria_store::NamedDimsArray, tolerances::NamedDimsArray)  

# Arguments
- `criteria_store` : contains criteria in each column for locations in each row.
- `tolerances` : contains thresholds for specified criteria, with keys matching those in criteria_store.
                Each key specifies the operation function >tolerance or <tolerance.

# Returns
- `criteria_store` : filtered version of criteria_store input.
"""
function filter_decision_matrix(criteria_store::NamedDimsArray, tolerances::NamedDimsArray)

    rule = sum(map.(tolerances.data, criteria_store(tolerances.criteria)'), dims=:criteria) .== length(tolerances.criteria)
    criteria_store = criteria_store[rule[criteria=1], :]

    return criteria_store
end


"""
    create_intervention_matrix(criteria_store::NamedDimsArray, params::NamedDimsArray, int_type::String)
  
# Arguments
- `criteria_store` : pre-filtered criteria to be used in the decision matrix for mcda.
- `params` : scenario parameters, must include weights for criteria for the intervention of interest.
- `int_type` : intervention type indicated as a string. Used to find relevant weights in `params`.

# Returns
- `S` : decision matrix for use in mcda technique of choice.
- 'ws': weights for each of the criteria in the decision matrix.

"""
function create_intervention_matrix(criteria_store::NamedDimsArray, params::NamedDimsArray, int_type::String)
    # Define intervention decision matrix
    int_params = params.factors[occursin.("iv__", params.factors).&occursin.(int_type, params.factors)]
    crit_inds = [findall.([occursin.(String(crit_name), int_params) for crit_name in criteria_store.criteria])...;]

    ws = mcda_normalize(Array(params(int_params)))
    S = Matrix(criteria_store[criteria=crit_inds])
    return S, ws
end


"""
    function guided_location_selection(criteria_store::NamedDimsArray, interventions::NamedTuple,
        params::NamedDimsArray, thresholds::NamedDimsArray, n_location_int::Int64,
        distances::Matrix, minimum_distance::Float64, use_dist::NamedTuple, int_logs::NamedDimsArray,
        pref_locations::NamedTuple, rankingsin::NamedTuple
    )::Tuple

# Arguments
- `criteria_store` : contains all criteria for all intervention types.
- `interventions` : has intervention type names as keys and specifies aggregation function for criteria_store for each intervention.
- `params` : parameters for particular scenario run of the model.
- `pref_locations` : previous time step's selection of locations for each intervention.
- `thresholds` : specifies risk filter thresholds for criteria_store.
- `n_location_int` : specifies number of locations to apply intervention at.
- `distances` : n_locations*n_locations, specifies Haversine distance between each location in the set.
- `minimum_distance` : specifies minimum allowed distance between selected locations.
- `use_dist` : specifies whether distance sorting should be used for each intervention.
- `int_logs` : specifies whether location selection should be performed for each intervention.
- `rankingsin` : pre-allocated store for location rankings for each intervention.

# Returns
Tuple :
    - `pref_locations` : n_location_int highest ranked locations for each intervention.
    - `rankings` : n_locations ⋅ 3 matrix holding [location_id, seeding_rank, shading_rank],
        Values of 0 indicate locations that were not considered
"""
function guided_location_selection(criteria_store::NamedDimsArray, interventions::NamedTuple,
    params::NamedDimsArray, thresholds::NamedDimsArray, n_location_int::Int64,
    distances::Matrix, minimum_distance::Float64, use_dist::NamedTuple, int_logs::NamedDimsArray,
    pref_locations::NamedTuple, rankingsin::NamedTuple
)::Tuple

    # location_id, seeding rank, shading rank
    mcda_func = mcda_methods[Int(params("guided"))]
    # filter criteria prior to decision making
    criteria_store = filter_decision_matrix(criteria_store, thresholds)

    if isempty(criteria_store)
        # if all rows filtered in risk filtering, abort
        return pref_locations, rankingsin
    end

    for int_key in keys(interventions)

        # if using intervention, create specific decision matrix
        if int_logs(int_key)

            # get criteria matrix aggregation for particular intervention
            criteria_store_temp = interventions[int_key](criteria_store)

            # cap to number of locations left after risk filtration
            n_location_int = min(n_location_int, length(criteria_store_temp.locations))
            location_ids::Array{Int64} = criteria_store_temp.locations
            location_ids = setdiff(location_ids, pref_locations[int_key])

            rankings = rankingsin[int_key]
            # Force different locations to be selected
            mod_n_ranks = min(size(rankings, 1), length(location_ids))
            if mod_n_ranks < length(criteria_store_temp.locations) && size(rankings, 1) != 0
                rankings = rankings[in.(rankings[:, 1], [location_ids]), :]
                location_ids = rankings[:, 1]

            elseif size(rankings, 1) != 0
                rankings = [location_ids zeros(Int64, length(location_ids))]
            end

            criteria_store_temp = criteria_store_temp[in.(criteria_store_temp.locations, [location_ids]), :]
            n_locations_all::Int64 = length(location_ids)

            if n_locations_all !== 0
                # create intervention matrix
                S, ws = create_intervention_matrix(criteria_store_temp, params, String(int_key))

                # pad with zeros incase less sites than n_location_int
                pref_locations[int_key] .= repeat([0], length(pref_locations[int_key]))

                if !isempty(S)
                    # get ranks for applying mcda_func to S
                    pref_locations_temp, l_order = rank_locations!(S, ws, rankings, n_location_int, criteria_store_temp.locations, mcda_func)

                    if use_dist[int_key] != 0
                        # sort sites for distance requirements
                        pref_locations_temp, rankings = distance_sorting(pref_locations_temp, l_order, distances, minimum_distance, rankings)

                    end

                    pref_locations[int_key][1:length(pref_locations_temp)] .= pref_locations_temp
                end
            end
            # Replace in put rankings if the selected locations exist
            if sum(pref_locations[int_key]) !== 0
                rankingsin[int_key][Bool.(dropdims(sum(in.(rankings[:, 1]', rankingsin[int_key][:, 1]), dims=2), dims=2)), 2] .= rankings[:, 2]
            end
        end
    end

    return pref_locations, rankingsin
end


"""
    distance_sorting(pref_locations::AbstractArray{Int}, location_order::AbstractVector, dist::Array{Float64}, dist_thresh::Float64)::AbstractArray{Int}

Find selected locations with distances between each other < dist_thresh*(median distance).
Replaces these locations with locations in the top_n ranks if the distance between these locations is greater.

# Arguments
- `pref_locations` : original n highest ranked locations selected for seeding or shading.
- `l_order` : current order of ranked locations in terms of numerical location ID.
- `dist` : Matrix of unique distances between locations.
- `min_dist` : minimum distance between locations for selected locations.
- `rankings` : contains rankings for location selection prior to distance sorting.

# Returns
- `rep_locations` : new set of selected locations for seeding or shading.
"""
function distance_sorting(pref_locations::AbstractArray{Int}, l_order::Matrix{Union{Float64,Int64}}, dist::Array{Float64},
    min_dist::Float64, rankings::Matrix{Int64})::Tuple{Vector{Union{Float64,Int64}},Matrix{Int64}}
    # set-up
    location_order = l_order[:, 1]
    # locations to select alternatives from
    alt_locations = setdiff(location_order, pref_locations)

    # find all selected locations closer than the min distance
    pref_dists = findall(dist[pref_locations, pref_locations] .< min_dist)

    # storage for new set of locations
    rep_locations = copy(pref_locations)

    if isempty(pref_dists)
        return pref_locations, rankings
    else
        # find indices to replace, replace maximum (lowest ranked) only
        inds_rep = maximum(sort(unique(reinterpret(Int64, pref_dists))))
        # number of locations to replace at each iteration
        select_n = 1

        # indices to keep
        inds_keep = collect(1:length(pref_locations))
        inds_keep = setdiff(inds_keep, inds_rep)

        while !isempty(alt_locations)
            rep_locations = [rep_locations[inds_keep[:]]; alt_locations[select_n]]
            # find all locations in current selection which are closer than allowed
            pref_dists = findall(dist[rep_locations, rep_locations] .< min_dist)
            if isempty(pref_dists)
                # if none break
                select_n = 0
                break
            else
                # Find index of the lowest ranked site which is too close
                inds_rep = maximum(sort(unique(reinterpret(Int64, pref_dists))))

                # Remove this location from the keeping set
                inds_keep = collect(1:length(pref_locations))
                inds_keep = setdiff(inds_keep, inds_rep)

                # remove checked locations from set of alternatives
                alt_locations = setdiff(alt_locations, alt_locations[1:select_n])

            end
        end
    end

    # If not all locations could be replaced, just use highest ranked remaining pref_locations
    if select_n != 0 && !all(pref_locations .== rep_locations)
        rem_pref_locations = setdiff(pref_locations, rep_locations)
        rep_locations[end-select_n+1:end] .= rem_pref_locations[1:select_n]
    end
    new_location_order = setdiff(location_order, rep_locations)
    new_location_order = [rep_locations; new_location_order]

    # add new location order to rankings
    l_order[:, 1] .= new_location_order

    align_rankings!(rankings, l_order)
    return rep_locations, rankings
end


"""
    retrieve_ranks(S::Matrix, weights::Array{Float64}, mcda_func::Function, location_ids::Array{Int64})

Get location ranks using mcda technique specified in mcda_func, weights and a decision matrix S.

# Arguments
- `S` : decision matrix containing criteria values for each location (n locations)*(m criteria)
- `weights` : importance weights for each criteria. 
- `mcda_func` : function to use for mcda, specified as an element from mcda_methods.
- `location_ids` : array of integers indicating location ids still remaining after filtering.

# Returns
- `l_order` : [location_ids, criteria values, ranks]
"""
function retrieve_ranks(S::Matrix, weights::Array{Float64}, mcda_func::Function, location_ids::Array{Int64})
    S = mcda_normalize(S)
    S .= S .* repeat(weights', size(S, 1), 1)
    scores = mcda_func(S)

    return retrieve_ranks(S, scores, true, location_ids)
end
function retrieve_ranks(S::Matrix, weights::Array, mcda_func::Vector, location_ids::Array{Int64})
    fns = repeat([maximum], length(weights))
    results = mcdm(MCDMSetting(S, weights, fns), mcda_func[1])

    return retrieve_ranks(S, results.scores, mcda_func[2], location_ids)
end
function retrieve_ranks(S::Matrix, scores::Array, rev_val::Bool, location_ids::Array{Int64})
    l_order = Union{Float64,Int64}[Int.(location_ids) scores 1:size(S, 1)]
    l_order .= sortslices(l_order, dims=1, by=x -> x[2], rev=rev_val)
    @views l_order[:, 3] .= Int.(1:size(S, 1))

    return l_order
end


"""
    location_selection(criteria_store::NamedDimsArray,  interventions::NamedTuple, scenario::NamedDimsArray, tolerances::NamedTuple,
        location_ids::AbstractArray, location_distances::Matrix, med_location_distance::Float64, n_location_int::Int64)

Perform location selection using a set of criteria, tolerances, locations and location distances.
# Arguments
- `criteria_store` : contains criteria for a single location selection instance.
- `interventions` : keys give keynames for each intervention to be used and aggregation functions for the decision matrix.
- `scenario` : contains parameters for a single location selection instance, including tolerance values 
and parameters for distance sorting.
- `tolerances` : specifies criteria tolerances and has keys with names corresponding to criteria in criteria_store. 
For example, (iv__heat_stress=(<,0.5)), implies the criteria "iv__heat_stress" must not have values greater than 0.5.
- `location_ids` : array of length nlocations containing indices of locations to be selected from.
- `location_distances` : Matrix of distances between locations.
- `med_location_distance` : Median distance between locations in the location_distances matrix.
- `n_location_int` : number of locations to select to perform intervention.

# Returns
- `ranks` : n_reps * locations * 3 (last dimension indicates: location_id, seeding rank, shading rank)
    containing ranks for single scenario.
"""
function location_selection(criteria_store::NamedDimsArray, interventions::NamedTuple, scenario::NamedDimsArray,
    tolerances::NamedTuple, int_logs::NamedDimsArray, location_ids::AbstractArray, location_distances::Matrix,
    med_location_distance::Float64, n_location_int::Int64)

    tolerances_store = create_tolerances_store(tolerances)
    min_distance = med_location_distance .* scenario("dist_thresh")
    n_locations = length(location_ids)

    # location_id, seeding rank, shading rank
    rankingsin = (seed=[location_ids zeros(Int64, (n_locations, 1))], fog=[location_ids zeros(Int64, (n_locations, 1))])
    pref_locations = (seed=zeros(Int, n_location_int), shade=zeros(Int, n_location_int), fog=zeros(Int, n_location_int))

    (_, ranks) = guided_location_selection(criteria_store, interventions, scenario, tolerances_store, n_location_int,
        location_distances, min_distance, (seed=true, fog=true, shade=false), int_logs,
        pref_locations, rankingsin)
    return ranks
end

"""
    run_location_selection(domain::Domain, scenarios::DataFrame, tolerances::NamedTuple, coral_covers::NamedDimsArray;
        aggregation_method=nothing, target_seed_locations=nothing, target_shade_locations=nothing)

Perform location selection for a given domain for multiple scenarios defined in a dataframe.

# Arguments
- `domain` : ADRIA Domain type, indicating geographical domain to perform location selection over.
- `scenarios` : DataFrame of criteria weightings and thresholds for each scenario.
- `tolerances` : NamedTuple specifying tolerances for pre-selection filtering. E.g. `tolerances = (iv__coral_cover=(>, x -> f_coral_cover(x)),
    iv__heat_stress=(<, x -> x), iv__wave_stress=(<, x -> x))`, where the keys correspond to criteria names in the Domain,
    the first element difines the filtering operation (> or <) and the second element defines the operation on the tolerance parameter
    (x->x is directly using parameter value). Tolerance values in `scenarios` DataFrame will have names "iv__"+(criteria name)+"__tol".
- `coral_covers` : contains coral covers for each selection scenario, size (N locations, M scenarios).
- `aggregation_method` : optional, specifies an additional aggregation method to apply on the output ranks,
    (e.g. `ranks_to_location_order` or `ranks_to_frequencies` ). Format is [aggregation_function, intervention_type], where
    intervention_type is a string (e.g. "seed").
- `target_seed_locations` : optional additional set of locations to only consider during seeding (must be a subset of the location ids in location data in Domain).
- `target_shade_locations` : optional additional set of locations to only consider during shading (must be a subset of the location ids in location data in Domain).

# Returns
- `ranks_store` : number of scenarios * locations * 3 (last dimension indicates: location_id, seed rank, shade rank)
    containing ranks for each scenario run.
- `aggregated_ranks_store` : if aggregation method is selected, the aggregated ranks_store output.
"""
function run_location_selection(domain::ADRIADomain, scenarios::DataFrame, tolerances::NamedTuple, coral_covers::NamedDimsArray;
    aggregation_method=nothing, target_seed_locations=nothing, target_shade_locations=nothing)

    ranks_store = NamedDimsArray(
        zeros(nrow(scenarios), length(domain.location_ids), 3),
        scenarios=1:nrow(scenarios),
        locations=domain.location_ids,
        ranks=["location_id", "seed_rank", "fog_rank"],
    )

    target_location_ids = Int64[]
    dhw_scens = domain.dhw_scens
    wave_scens = domain.wave_scens

    if !isnothing(target_seed_locations)
        append!(target_location_ids, target_seed_locations)
    end

    if !isnothing(target_shade_locations)
        append!(target_location_ids, target_shade_locations)
    end

    int_logs = NamedDimsArray([(scenarios.seed_CA .> 0) .& (scenarios.seed_TA .> 0) scenarios.fogging .> 0 Bool.(zeros(length(scenarios.fogging)))],
        scenarios=1:length(scenarios.fogging), log=[:seed, :fog, :shade])

    # Pre-calculate maximum depth to consider
    scenarios[:, "max_depth"] .= scenarios.depth_min .+ scenarios.depth_offset
    criteria_store = create_criteria_store(collect(1:length(domain.location_ids)), domain.mcda_criteria)

    coral_cover, coral_space = coral_cover_criteria(domain.location_data, coral_covers)

    in_connectivity = connectivity_criteria(domain.in_conn, coral_covers, domain.location_data.area)
    out_connectivity = connectivity_criteria(domain.out_conn, coral_covers, domain.location_data.area)

    criteria_store(:iv__wave_stress) .= env_stress_criteria(Array(dropdims(mean(wave_scens, dims=(:timesteps, :scenarios)) .+ var(wave_scens, dims=(:timesteps, :scenarios)), dims=:timesteps)))
    criteria_store(:iv__heat_stress) .= env_stress_criteria(Array(dropdims(mean(dhw_scens, dims=(:timesteps, :scenarios)) .+ var(dhw_scens, dims=(:timesteps, :scenarios)), dims=:timesteps)))

    for (cover_ind, scen) in enumerate(eachrow(scenarios))

        tol_temp = ()
        for tol = keys(tolerances)
            tol_temp = (; tol_temp..., tol => (tolerances[tol][1], map(tolerances[tol][2], scen[string(String(tol), "__tol")])))
        end

        depth_criteria = (domain.location_data.depth_med .<= scen.max_depth) .& (domain.location_data.depth_med .>= scen.depth_min)
        depth_priority = findall(depth_criteria)

        criteria_store(:iv__coral_cover) .= coral_cover[scenarios=cover_ind]
        criteria_store(:iv__coral_space) .= coral_space[scenarios=cover_ind]
        criteria_store(:iv__in_connectivity) .= in_connectivity[scenarios=cover_ind]
        criteria_store(:iv__out_connectivity) .= out_connectivity[scenarios=cover_ind]

        considered_locations = unique(target_location_ids[findall(in(depth_priority), target_location_ids)])
        scen_set = NamedDimsArray(Vector(scen), factors=names(scen))

        temp_ranks = location_selection(criteria_store[locations=considered_locations],
            domain.interventions,
            scen_set,
            tol_temp,
            int_logs[scenarios=cover_ind],
            considered_locations,
            domain.location_distances,
            domain.median_location_distance,
            domain.sim_constants.n_location_int
        )

        ranks_store(scenarios=cover_ind, locations=domain.location_ids[considered_locations], ranks="seed_rank") .= temp_ranks[:seed][:, 2]
        ranks_store(scenarios=cover_ind, locations=domain.location_ids[considered_locations], ranks="fog_rank") .= temp_ranks[:fog][:, 2]

    end
    if !isnothing(aggregation_method)
        return ranks_store, aggregation_method[1](ranks_store, aggregation_method[2])
    else
        return ranks_store
    end
end


"""
    unguided_location_selection(prefseedlocations, prefshadelocations, seed_years, shade_years, n_location_int, max_cover)

Randomly select seed/shade location locations for the given year, constraining to locations with max. carrying capacity > 0.
Here, `max_cover` represents the max. carrying capacity for each location (the `k` value).

# Arguments
- `pref_locations` : Previously selected locations
- `int_log` : bool, indicating whether each intervention occurs this year or not.
- `n_location_int` : int, number of locations to intervene on
- `available_space` : vector/matrix : space available at each location (`k` value)
- `depth` : vector of location ids found to be within desired depth range.
- 'clusters' : vector of cluster identifiers.
"""
function unguided_location_selection(pref_locations, int_logs, n_location_int, available_space, depth, clusters)
    # Unguided deployment, seed/shade corals anywhere so long as available_space > 0.1
    # Only locations that have available space are considered, otherwise a zero-division error may occur later on.

    # Select locations (without replacement to avoid duplicate locations)
    candidate_locations = depth[(available_space.>0.0)[depth]]  # Filter down to location ids to be considered
    num_locations = length(candidate_locations)
    s_n_location_int = num_locations < n_location_int ? num_locations : n_location_int
    s_n_location_int_shade = length(clusters) < n_location_int ? length(clusters) : n_location_int

    for int_key in [:seed, :fog]
        if int_logs(int_key)
            pref_locations[int_key] .= zeros(Int64, n_location_int)
            pref_locations[int_key][1:s_n_location_int] .= StatsBase.sample(candidate_locations, s_n_location_int; replace=false)

        end
    end

    if int_logs(:shade)
        pref_locations[:shade] .= StatsBase.sample(clusters, s_n_location_int_shade; replace=false)
    end

    return pref_locations
end


