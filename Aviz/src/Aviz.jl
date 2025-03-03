module Aviz

using Base.Iterators
using Reexport

using RelocatableFolders, FileIO
using ImageMagick
using GLMakie
@reexport using GeoMakie
# using GLMakie.GeometryBasics
using Statistics, Distributions, ThreadsX, Random

using DataFrames, Bootstrap  # , DecisionTree

using GeoInterface
import GeoDataFrames as GDF
import GeoFormatTypes as GFT
import GeoMakie.GeoJSON.FeatureCollection as FC

using ADRIA: load_results, load_domain, load_scenarios, ResultSet, run_scenarios, metrics
import ADRIA: timesteps as AD_timesteps


Random.seed!(101)

const ASSETS = @path joinpath(@__DIR__, "../assets")
const LOGO = @path joinpath(ASSETS, "imgs", "ADRIA_logo.png")
const LOADER = @path joinpath(ASSETS, "imgs", "ADRIA_loader.gif")


include("./plotting.jl")
include("./layout.jl")
include("./theme.jl")
include("./spatial.jl")
# include("./rf_analysis.jl")
include("./analysis.jl")
include("./viz/viz.jl")


"""Main entry point for app."""
function julia_main()::Cint
    if "explore" in ARGS
        rs_pkg = ARGS[2]
        explore(rs_pkg)
        return 0
    end

    if "run" in ARGS
        domain_loc = ARGS[2]
        rcp_id = ARGS[3]
        input_set = ARGS[4]

        dom = load_domain(domain_loc, rcp_id)
        p_df = load_scenarios(dom, input_set)

        rs = run_scenarios(p_df, dom)
        explore(rs)
        return 0
    end

    main_menu()

    return 0
end

function main_menu()
    f = Figure()

    logo = image(
        f[1, 1],
        rotr90(load(convert(String, LOGO))),
        axis=(aspect=DataAspect(),)
    )

    hidedecorations!(f.content[1])
    hidespines!(f.content[1])

    Label(f[2, 1], "Enter ADRIA Result Set to analyze")
    rs_path_tb = Textbox(f[3, 1], placeholder="./Moore_RS")
    rs_path_tb.stored_string[] = "./Moore_RS"
    status_label = Label(f[4, 1], "")

    launch_button = Button(f[5, 1], label="Explore")

    on(launch_button.clicks) do c
        rs_path = rs_path_tb.stored_string[]
        if !isnothing(rs_path) && ispath(rs_path)
            status_label.text[] = "Loading Result Set..."
            rs = nothing
            try
                rs = load_results(rs_path)
            catch
                rs_path_tb.bordercolor = :red
                status_label.text[] = "Invalid ADRIA Result Set"
            else
                # Clear current figure and launch new display
                empty!(f)
                explore(rs)
            end
        else
            rs_path_tb.bordercolor = :red
            status_label.text[] = "Invalid path"
        end
    end

    gl_screen = display(f)
    wait(gl_screen)
end


function _get_seeded_sites(seed_log, ts, scens; N=10)
    t = dropdims(sum(seed_log[timesteps=ts, scenarios=scens], dims=:timesteps), dims=:timesteps)
    site_scores = dropdims(sum(t, dims=:scenarios), dims=:scenarios)

    # @info "Scores", site_scores
    if length(unique(site_scores)) == 1
        return zeros(Int64, N)
    end

    return sortperm(site_scores)[1:N]
end

function display_loader(fig, anim)
    a = image(fig[1, 1], anim[:, :, 1])
    hidedecorations!(a.axis)
    hidespines!(a.axis)

    for i in cycle(axes(anim, 3))
        image!(a.axis, anim[:, :, i])

        sleep(0.1)
    end
end
function remove_loader(fig, task)
    Base.throwto(task, InterruptException())
    empty!(fig)
end

"""
    explore(rs::String)
    explore(rs::ResultSet)

Display GUI for quick visualization and analysis of results.
"""
function explore(rs::ResultSet)
    layout = comms_layout(resolution=(1920, 1080))

    f = layout.figure
    # controls = layout.controls
    traj_display = layout.trajectory.temporal
    traj_outcome_sld = layout.trajectory.outcome_slider
    traj_time_sld = layout.trajectory.time_slider

    # Generate trajectory
    tac_scens = metrics.scenario_total_cover(rs)
    tac_data = Matrix(tac_scens')
    tac_min_max = (minimum(tac_scens), maximum(tac_scens))

    # Generate trajectory controls
    num_steps = Int(ceil((tac_min_max[2] - tac_min_max[1]) + 1))
    tac_slider = IntervalSlider(traj_outcome_sld[2, 1],
        range=LinRange(floor(Int64, tac_min_max[1]) - 1, ceil(Int64, tac_min_max[2]) + 1, num_steps),
        startvalues=tac_min_max,
        horizontal=false
    )

    # Dynamic label text for TAC slider
    tac_bot_val = Observable(floor(tac_min_max[1]) - 1)
    tac_top_val = Observable(ceil(tac_min_max[2]) + 1)
    Label(traj_outcome_sld[1, 1], @lift("$(round($tac_top_val / 1e6, digits=2)) M (m²)"))
    Label(traj_outcome_sld[3, 1], @lift("$(round($tac_bot_val / 1e6, digits=2)) M (m²)"))

    # Time slider
    years = AD_timesteps(rs)
    year_range = first(years), last(years)
    time_slider = IntervalSlider(
        traj_time_sld[1, 2:3],
        range=LinRange(year_range[1], year_range[2], (year_range[2] - year_range[1]) + 1),
        startvalues=year_range
    )

    # Dynamic label text for TAC slider
    left_year_val = Observable("$(year_range[1])")
    right_year_val = Observable("$(year_range[2])")
    Label(traj_time_sld[1, 1], left_year_val)
    Label(traj_time_sld[1, 4], right_year_val)

    # Generate map
    map_display = layout.map

    # Get bounds to display
    centroids = rs.site_centroids
    mean_rc_sites = metrics.relative_cover(rs)
    obs_rc = vec(mean(mean_rc_sites, dims=(:scenarios, :timesteps)))
    obs_mean_rc_sites = Observable(obs_rc)

    # Placeholder store to control which trajectories are visible
    X = rs.inputs
    min_color_step = (1.0 / 0.05)
    init_weight = (1.0 / (size(X, 1) / min_color_step))
    color_map = scenario_colors(rs, init_weight)
    obs_color = Observable(color_map)
    scen_types = scenario_type(rs)

    seed_log = rs.seed_log[:, 1, :, :]

    # Trajectories
    series!(traj_display, years, tac_data, color=obs_color)

    # Density (TODO: Separate into own function)
    tac_scen_dist = dropdims(mean(tac_scens, dims=:timesteps), dims=:timesteps)
    obs_cf_scen_dist = Observable(tac_scen_dist[scen_types.counterfactual])
    obs_ug_scen_dist = Observable(tac_scen_dist[scen_types.unguided])
    obs_g_scen_dist = Observable(tac_scen_dist[scen_types.guided])

    # Color transparency for density plots
    # Note: Density plots currently cannot handle empty datasets
    #       as what might happen if user selects a region with no results.
    #       so instead we set alpha to 0.0 to hide it.
    cf_hist_alpha = Observable((:red, 0.5))
    ug_hist_alpha = Observable((:green, 0.5))  # Observable(0.5)
    g_hist_alpha = Observable((:blue, 0.5))

    # Legend(traj_display)  legend=["Counterfactual", "Unguided", "Guided"]
    scen_hist = layout.scen_hist
    density!(scen_hist, obs_cf_scen_dist, direction=:y, color=cf_hist_alpha)
    density!(scen_hist, obs_ug_scen_dist, direction=:y, color=ug_hist_alpha)
    density!(scen_hist, obs_g_scen_dist, direction=:y, color=g_hist_alpha)
    hidedecorations!(scen_hist)
    hidespines!(scen_hist)
    ylims!(scen_hist, 0.0, maximum(tac_scen_dist))

    # Random forest stuff
    # Feature importance
    # layout.outcomes
    # ft_import = layout.importance

    # https://github.dev/JuliaAI/DecisionTree.jl
    # X = Matrix(rs.inputs)
    # p = outcome_probability(tac_scen_dist)
    # model = build_forest(p, X, ceil(Int, sqrt(size(X, 1))), 30, 0.7, -1; rng=101)
    # p_tbl = probability_table(model, X, p)
    # @time ft_tbl = ft_importance(model, rs.inputs, p; rng=101)

    asv_scens = metrics.scenario_asv(rs)
    asv_scen_dist = dropdims(mean(asv_scens, dims=:timesteps), dims=:timesteps)

    juves_scens = metrics.scenario_relative_juveniles(rs)
    juves_scen_dist = dropdims(mean(juves_scens, dims=:timesteps), dims=:timesteps)

    ms = rs.model_spec
    intervention_components = ms[(ms.component.=="Intervention").&(ms.fieldname.!="guided"), [:fieldname, :bounds]]
    interv_names = intervention_components.fieldname
    interv_idx = findall(x -> x in interv_names, names(X))

    # Adjust unguided scenarios so scenario values are not 0 (to avoid these getting removed in display)
    for (i, n) in enumerate(interv_names)
        fb = intervention_components[i, :bounds]
        x = eval(Meta.parse(fb))
        X[X.guided.<0, n] .= x[1]
    end

    mean_tac_med = relative_sensitivities(X, Array(tac_scen_dist))
    mean_tac_med = mean_tac_med[interv_idx]

    mean_asv_med = relative_sensitivities(X, Array(asv_scen_dist))
    mean_asv_med = mean_asv_med[interv_idx]

    mean_juves_med = relative_sensitivities(X, Array(juves_scen_dist))
    mean_juves_med = mean_juves_med[interv_idx]

    # sample_cv = std(tac_scen_dist) ./ mean(tac_scen_dist)
    # cf_cv = std(tac_scen_dist[scen_types.counterfactual]) ./ mean(tac_scen_dist[scen_types.counterfactual])
    # ug_cv = std(tac_scen_dist[scen_types.unguided]) ./ mean(tac_scen_dist[scen_types.unguided])
    # g_cv = std(tac_scen_dist[scen_types.guided]) ./ mean(tac_scen_dist[scen_types.guided])

    ft_import = Axis(
        layout.importance[1, 1],
        xticks=([1, 2, 3], ["Mean TAC", "Mean ASV", "Mean Juveniles"]),
        yticks=(1:length(interv_names), interv_names),
        title="Relative Importance"
    )
    ft_import.yreversed = true

    S_data = hcat(mean_tac_med, mean_asv_med, mean_juves_med)'
    sensitivities = Observable(S_data)
    heatmap!(ft_import, sensitivities)
    Colorbar(layout.importance[1, 2]; colorrange=(0.0, 1.0))

    # TODO: Separate this out into own function
    # Make temporary copy of GeoPackage as GeoJSON
    tmpdir = mktempdir()

    local geo_fn = joinpath(tmpdir, "Aviz_$(rs.name).geojson")
    try
        GDF.write(geo_fn, rs.site_data; driver="geojson")
    catch
        GDF.write(geo_fn, rs.site_data; geom_columns=(:geom,), driver="geojson")
    end
    geodata = GeoMakie.GeoJSON.read(read(geo_fn))

    map_disp = create_map!(map_display, geodata, obs_mean_rc_sites, (:black, 0.05), centroids)
    curr_highlighted_sites = _get_seeded_sites(seed_log, (:), (:))

    obs_site_sel = FC(geodata[curr_highlighted_sites, :][:])
    obs_site_sel = Observable(obs_site_sel)
    obs_site_highlight = Observable((:lightgreen, 1.0))
    overlay_site = poly!(map_disp, obs_site_sel, color=(:white, 0.0), strokecolor=obs_site_highlight, strokewidth=0.75, overdraw=true)

    # Add control grid
    # Controls for RCPs
    t_toggles = [Toggle(f, active=active) for active in [true, true, true, true, true, true]]
    t_toggle_map = zip(
        t_toggles,
        ["RCP 4.5", "RCP 6.0", "RCP 8.5", "Counterfactual", "Unguided", "Guided"],
        [:black, :black, :black, :red, :green, :blue]
    )
    labels = [Label(f, "$l", color=lift(x -> x ? c : :gray, t.active)) for (t, l, c) in t_toggle_map]
    layout.controls[1:2, 1] = grid!(hcat(t_toggles, labels), tellheight=false)

    # Controls for guided type
    guide_toggle_map = zip(
        t_toggles[3:end],
        ["Counterfactual", "Unguided", "Guided"],
        [:red, :green, :blue]
    )

    # Controls for interventions
    interv_sliders = IntervalSlider[]
    interv_labels = []
    lc = layout.controls[3:6, 1] = GridLayout()
    for (i, v) in enumerate(eachrow(intervention_components))
        fn = v[1]
        x = eval(Meta.parse(v[2]))

        l1 = Observable("$(round(x[1], digits=2))")
        l2 = Observable("$(round(x[2], digits=2))")
        push!(interv_sliders,
            IntervalSlider(
                lc[i, 2],
                range=LinRange(x[1], x[2], 10),
                startvalues=(x[1], x[2])
            )
        )

        push!(interv_labels, [l1, l2])

        Label(lc[i, 2], fn)
        Label(lc[i, 1], l1)
        Label(lc[i, 3], l2)
    end

    scen_dist = tac_scen_dist
    hide_idx = falses(size(X, 1))
    show_idx = trues(size(X, 1))

    outcomes_ax = layout.outcomes
    probas = Observable(outcome_probability(scen_dist))
    barplot!(
        outcomes_ax,
        @lift($(probas).values),
        bar_labels=:y,
        direction=:y,
        flip_labels_at=@lift(maximum($(probas).values) * 0.9),
        color_over_bar=:white,
        grid=false,
        xticklabelsize=12
    )
    hideydecorations!(outcomes_ax)

    # Image file for loading animation
    # loader_anim = load(LOADER)

    function update_disp(time_val, tac_val, rcp45, rcp60, rcp85, c_tog, u_tog, g_tog, disp_vals...)
        # Display loading animation
        # load_anim_display = @async display_loader(traj_display[2, 1], loader_anim)

        # Convert time ranges to index values
        timespan = floor(Int, time_val[1] - (year_range[1]) + 1):ceil(Int, time_val[2] - (year_range[1]) + 1)

        show_idx .= trues(size(X, 1))

        # Update according to intervention slider values
        # Hide scenarios that do not meet selections based on selected intervention values
        # disp_vals = [i1_val, i2_val, i3_val, i4_val, i5_val, i6_val, i7_val, i8_val, i9_val, i10_val, i11_val]
        for (intv, bnds) in enumerate(interv_labels)
            bnds[1][] = "$(round(disp_vals[intv][1], digits=2))"
            bnds[2][] = "$(round(disp_vals[intv][2], digits=2))"

            show_idx .= show_idx .& ((X[:, interv_names[intv]] .>= disp_vals[intv][1]) .& (X[:, interv_names[intv]] .<= disp_vals[intv][2]))
        end

        # Hide/display scenario types
        if c_tog
            show_idx .= show_idx .| (X.guided .== -1.0)
        else
            show_idx .= show_idx .& (X.guided .!= -1.0)
        end

        if !u_tog
            show_idx .= show_idx .& (X.guided .!= 0.0)
        end
        if !g_tog
            show_idx .= show_idx .& (X.guided .<= 0.0)
        end

        if !rcp45
            show_idx .= show_idx .& (X.RCP .!= 45)
        end

        if !rcp60
            show_idx .= show_idx .& (X.RCP .!= 60)
        end

        if !rcp85
            show_idx .= show_idx .& (X.RCP .!= 85)
        end

        # Update hidden scenarios with inverse of show
        hide_idx .= Bool.(ones(Int64, length(hide_idx)) .⊻ show_idx)

        # Update map
        obs_mean_rc_sites[] = vec(mean(mean_rc_sites[timesteps=timespan][scenarios=show_idx], dims=(:scenarios, :timesteps)))

        seeded_sites = _get_seeded_sites(seed_log, (:), show_idx)
        site_alpha = 1.0
        if seeded_sites != curr_highlighted_sites
            # Highlight seeded sites
            if any(seeded_sites .> 0.0) && any(show_idx)
                obs_site_sel[] = FC(geodata[seeded_sites, :])
                site_alpha = 1.0
                curr_highlighted_sites .= seeded_sites
            else
                site_alpha = 0.0
            end
        elseif all(seeded_sites .== 0.0) || all(show_idx .== 0)
            site_alpha = 0.0
        end

        obs_site_highlight[] = (:lightgreen, site_alpha)

        # Update scenario density
        scen_dist = dropdims(mean(tac_scens[timesteps=timespan], dims=:timesteps), dims=:timesteps)
        # Hide scenarios that were filtered out
        cf_dist = scen_dist[show_idx.&scen_types.counterfactual]
        ug_dist = scen_dist[show_idx.&scen_types.unguided]
        g_dist = scen_dist[show_idx.&scen_types.guided]

        if c_tog && !isempty(cf_dist)
            obs_cf_scen_dist[] = cf_dist
            cf_hist_alpha[] = (:red, 0.5)
        else
            cf_hist_alpha[] = (:red, 0.0)
        end

        if u_tog && !isempty(ug_dist)
            obs_ug_scen_dist[] = ug_dist
            ug_hist_alpha[] = (:green, 0.5)
        else
            ug_hist_alpha[] = (:green, 0.0)
        end

        if g_tog && !isempty(g_dist)
            obs_g_scen_dist[] = g_dist
            g_hist_alpha[] = (:blue, 0.5)
        else
            g_hist_alpha[] = (:blue, 0.0)
        end

        # Update limits of density plot
        autolimits!(scen_hist)

        # Update visible trajectories
        # Determine level of transparency for each line (maximum of 0.5)
        color_weight = min((1.0 / (count(show_idx .> 0) / min_color_step)), 0.5)
        scenario_colors!(obs_color, color_map, scen_types, color_weight, hide_idx, guide_toggle_map)

        # Update sensitivities (if there's enough samples...)
        if count(show_idx) > 16
            mean_tac_med = relative_sensitivities(X[show_idx, :], scen_dist[show_idx])[interv_idx]

            sel_asv_scens = dropdims(mean(asv_scens[timesteps=timespan, scenarios=show_idx], dims=:timesteps), dims=:timesteps)
            mean_asv_med = relative_sensitivities(X[show_idx, :], sel_asv_scens)[interv_idx]

            sel_juves_scens = dropdims(mean(juves_scens[timesteps=timespan, scenarios=show_idx], dims=:timesteps), dims=:timesteps)
            mean_juves_med = relative_sensitivities(X[show_idx, :], sel_juves_scens)[interv_idx]
        else
            # Display nothing if no data is available
            mean_tac_med = fill(NaN, length(interv_idx))
            mean_asv_med = fill(NaN, length(interv_idx))
            mean_juves_med = fill(NaN, length(interv_idx))
        end

        S_data[1, :] .= mean_tac_med
        S_data[2, :] .= mean_asv_med
        S_data[3, :] .= mean_juves_med
        sensitivities[] = S_data

        # Update bar plot of outcome probability
        probas[] = outcome_probability(scen_dist[show_idx])
        ylims!(layout.outcomes, minimum(probas[].values), maximum(probas[].values))

        # Clear loading animation
        # remove_loader(traj_display[2, 1], loader_anim_display)
    end

    # Trigger update only after some time since last interaction
    # TODO: Add update notification (spinner animation or something...)
    up_timer = Timer(x -> x, 0.25)
    onany(time_slider.interval, tac_slider.interval,
        [t.active for t in t_toggles]...,
        [sld.interval for sld in interv_sliders]...) do time_val, tac_val, rcp45, rcp60, rcp85, c_tog, u_tog, g_tog, i1_val, i2_val, i3_val, i4_val, i5_val, i6_val, i7_val, i8_val, i9_val, i10_val, i11_val

        # Update slider labels
        left_year_val[] = "$(Int(floor(time_val[1])))"
        right_year_val[] = "$(Int(ceil(time_val[2])))"
        tac_bot_val[] = tac_val[1]
        tac_top_val[] = tac_val[2]

        close(up_timer)
        up_timer = Timer(x -> update_disp(time_val, tac_val, rcp45, rcp60, rcp85, c_tog, u_tog, g_tog, i1_val, i2_val, i3_val, i4_val, i5_val, i6_val, i7_val, i8_val, i9_val, i10_val, i11_val), 2)
    end

    gl_screen = display(f)
    # DataInspector()

    wait(gl_screen)
end
function explore(rs_path::String)
    explore(ADRIA.load_results(rs_path))
end


# function explore(rs::ADRIA.ResultSet)
#     layout = modeler_layout(resolution=(1920, 1080))

#     f = layout.figure
#     # controls = layout.controls
#     traj_display = layout.trajectory.temporal
#     traj_outcome_sld = layout.trajectory.outcome_slider
#     traj_time_sld = layout.trajectory.time_slider

#     scen_hist = layout.scen_hist
#     map_display = layout.map

#     interv_pcp_display = layout.interv_pcp
#     pair_display = layout.pairplot
#     outcome_pcp_display = layout.outcome_pcp

#     colsize!(f.layout, 1, Fixed(400))
#     colsize!(f.layout, 2, Fixed(1100))

#     color_map = scenario_colors(rs)
#     obs_color = Observable(color_map)

#     # n_visible_scenarios = Observable(size(rs.inputs, 1))
#     # seed_log = rs.seed_log[:, 1, :, :]

#     # Temporal controls
#     tac_scens = ADRIA.metrics.scenario_total_cover(rs)
#     # rc_scens = ADRIA.metrics.scenario_relative_cover(rs)
#     mean_tac_outcomes = vec(mean(tac_scens, dims=1))
#     # mean_rc_outcomes = vec(mean(rc_scens, dims=1))
#     tac_min_max = (minimum(tac_scens), maximum(tac_scens))

#     # tac_label = Label(traj_outcome_sld[1,1], "Mean TAC (m²)")  # , rotation = pi/2
#     num_steps = Int(ceil((tac_min_max[2] - tac_min_max[1]) + 1))
#     tac_slider = IntervalSlider(traj_outcome_sld[2, 1],
#         range=LinRange(floor(Int64, tac_min_max[1]) - 1, ceil(Int64, tac_min_max[2]) + 1, num_steps),
#         startvalues=tac_min_max,
#         horizontal=false
#         # width=350
#     )

#     # Dynamic label text for TAC slider
#     tac_bot_val = Observable(floor(tac_min_max[1]) - 1)
#     tac_top_val = Observable(ceil(tac_min_max[2]) + 1)

#     tac_bot = @lift("$(round($tac_bot_val / 1e6, digits=2))")
#     tac_top = @lift("$(round($tac_top_val / 1e6, digits=2))")
#     Label(traj_outcome_sld[1, 1], tac_top)
#     Label(traj_outcome_sld[3, 1], tac_bot)

#     # Time slider
#     years = timesteps(rs)
#     year_range = first(years), last(years)
#     time_slider = IntervalSlider(
#         traj_time_sld[1, 2],
#         range=LinRange(year_range[1], year_range[2], (year_range[2] - year_range[1]) + 1),
#         startvalues=year_range
#     )

#     # Dynamic label text for TAC slider
#     left_year_val = Observable("$(year_range[1])")
#     right_year_val = Observable("$(year_range[2])")
#     Label(traj_time_sld[1, 1], left_year_val)
#     Label(traj_time_sld[1, 3], right_year_val)

#     tac = ADRIA.metrics.scenario_total_cover(rs)
#     tac_data = Matrix(tac')

#     # asv = ADRIA.metrics.scenario_asv(rs)

#     # Histogram/Density plot
#     scen_types = scenario_type(rs)

#     scen_dist = dropdims(mean(tac, dims=:timesteps), dims=:timesteps)
#     # scen_dist = vec(mean(scen_dist, dims=:sites))

#     cf_scen_dist = scen_dist[scen_types.counterfactual]
#     ug_scen_dist = scen_dist[scen_types.unguided]
#     g_scen_dist = scen_dist[scen_types.guided]

#     obs_cf_scen_dist = Observable(cf_scen_dist)
#     obs_ug_scen_dist = Observable(ug_scen_dist)
#     obs_g_scen_dist = Observable(g_scen_dist)

#     # Color transparency for density plots
#     # Note: Density plots currently cannot handle empty datasets
#     #       as what might happen if user selects a region with no results.
#     #       so instead we set alpha to 0.0 to hide it.
#     cf_hist_alpha = Observable(0.5)
#     ug_hist_alpha = Observable(0.5)
#     g_hist_alpha = Observable(0.5)

#     # Get intervention/criteria inputs for each scenario
#     interv_criteria = ms[(ms.component.=="EnvironmentalLayer").|(ms.component.=="Intervention").|(ms.component.=="Criteria"), [:fieldname, :full_bounds]]
#     input_names = vcat(["RCP", interv_criteria.fieldname...])
#     in_pcp_data = normalize(Matrix(rs.inputs[:, input_names]))
#     # in_pcp_lines = Observable(in_pcp_data)


#     # Get mean outcomes for each scenario
#     outcome_pcp_data = hcat([
#         mean_tac_outcomes,
#         vec(mean(ADRIA.metrics.scenario_asv(rs), dims=1)),
#         vec(mean(ADRIA.metrics.scenario_rsv(rs), dims=1))
#     ]...)
#     disp_names = ["TAC", "ASV", "RSV"]

#     out_pcp_data = normalize(outcome_pcp_data)

#     # Specify interactive elements and behavior
#     # TODO: Lift on data to be plotted
#     #       Controls simply update transparency settings etc, and update the dataset to be plotted
#     #       All other elements simply update when the underlying dataset updates
#     # https://discourse.julialang.org/t/interactive-plot-with-makielayout/48843
#     onany(time_slider.interval, tac_slider.interval) do time_val, tac_val
#         # Update slider labels
#         tac_bot_val[] = tac_val[1]
#         tac_top_val[] = tac_val[2]

#         left_year_val[] = "$(Int(floor(time_val[1])))"
#         right_year_val[] = "$(Int(ceil(time_val[2])))"

#         # Trajectories
#         # tac_idx = (mean_tac_outcomes .>= tac_val[1]-0.5) .& (mean_tac_outcomes .<= tac_val[2]+0.5)

#         # Convert time ranges to index values
#         t_idx = Int(time_val[1] - (year_range[1]) + 1), Int(time_val[2] - (year_range[1]) + 1)

#         hide_idx = vec(all((tac_val[1] .<= tac_scens[t_idx[1]:t_idx[2], :] .<= tac_val[2]) .== 0, dims=1))
#         show_idx = Bool.(zeros(Int64, length(hide_idx)) .⊻ hide_idx)  # inverse of hide

#         scen_dist = dropdims(mean(tac[timesteps=t_idx[1]:t_idx[2]], dims=:timesteps), dims=:timesteps)

#         # Boolean index of scenarios to hide (inverse of tac_idx)
#         # hide_idx = Bool.(ones(Int64, length(tac_idx)) .⊻ tac_idx)
#         if !all(hide_idx .== 0)
#             # Hide scenarios that were filtered out
#             cf_dist = scen_dist[show_idx.&scen_types.counterfactual]
#             ug_dist = scen_dist[show_idx.&scen_types.unguided]
#             g_dist = scen_dist[show_idx.&scen_types.guided]
#         else
#             cf_dist = scen_dist[scen_types.counterfactual]
#             ug_dist = scen_dist[scen_types.unguided]
#             g_dist = scen_dist[scen_types.guided]
#         end

#         # Update scenario density plot
#         if !isempty(cf_dist)
#             obs_cf_scen_dist[] = cf_dist
#             cf_hist_alpha[] = 0.5
#         else
#             cf_hist_alpha[] = 0.0
#         end

#         if !isempty(ug_dist)
#             obs_ug_scen_dist[] = ug_dist
#             ug_hist_alpha[] = 0.5
#         else
#             ug_hist_alpha[] = 0.0
#         end

#         if !isempty(g_dist)
#             obs_g_scen_dist[] = g_dist
#             g_hist_alpha[] = 0.5
#         else
#             g_hist_alpha[] = 0.0
#         end

#         # Determine level of transparency for each line (maximum of 0.6)
#         min_step = (1 / 0.05)
#         color_weight = min((1.0 / (count(show_idx .> 0) / min_step)), 0.6)

#         obs_color[] = scenario_colors(rs, color_weight, hide_idx)
#     end

#     # Trajectories
#     # series!(traj_display, timesteps(rs), tac_data, color=@lift($obs_color[:]))
#     series!(traj_display, timesteps(rs), tac_data, color=obs_color)

#     # Legend(traj_display)  legend=["Counterfactual", "Unguided", "Guided"]
#     density!(scen_hist, @lift($obs_cf_scen_dist[:]), direction=:y, color=(:red, cf_hist_alpha))
#     density!(scen_hist, @lift($obs_ug_scen_dist[:]), direction=:y, color=(:green, ug_hist_alpha))
#     density!(scen_hist, @lift($obs_g_scen_dist[:]), direction=:y, color=(:blue, g_hist_alpha))

#     hidedecorations!(scen_hist)
#     hidespines!(scen_hist)

#     # TODO: Separate this out into own function
#     # Make temporary copy of GeoPackage as GeoJSON
#     tmpdir = mktempdir()
#     geo_fn = GDF.write(joinpath(tmpdir, "Aviz_$(rs.name).geojson"), rs.site_data; driver="geojson")
#     geodata = GeoMakie.GeoJSON.read(read(geo_fn))

#     # Get bounds to display
#     centroids = rs.site_centroids
#     lon = first.(centroids)
#     lat = last.(centroids)

#     # Display map
#     mean_rc_sites = mean(ADRIA.metrics.relative_cover(rs), dims=(:scenarios, :timesteps))
#     map_buffer = 0.005
#     spatial = GeoAxis(
#         map_display;  # any cell of the figure's layout
#         lonlims=(minimum(lon) - map_buffer, maximum(lon) + map_buffer),
#         latlims=(minimum(lat) - map_buffer, maximum(lat) + map_buffer),
#         xlabel="Long",
#         ylabel="Lat",
#         dest="+proj=latlong +datum=WGS84"
#     )

#     poly!(spatial, geodata, color=vec(mean_rc_sites), colormap=:plasma)
#     datalims!(spatial)

#     # Fill pairplot
#     # Get mean outcomes for each scenario
#     pairplot!(pair_display, outcome_pcp_data, disp_names)

#     # Parallel Coordinate Plot
#     pcp!(interv_pcp_display, in_pcp_data, input_names; color=@lift($obs_color[:]))
#     pcp!(outcome_pcp_display, out_pcp_data, disp_names; color=@lift($obs_color[:]))

#     gl_screen = display(f)
#     DataInspector()

#     wait(gl_screen)
# end
# function explore(rs_path::String)
#     explore(ADRIA.load_results(rs_path))
# end

end


# Allow use from terminal if this file is run directly
if abspath(PROGRAM_FILE) == @__FILE__
    if "explore" in ARGS
        rs_pkg = ARGS[2]
        Aviz.explore(rs_pkg)
    end
end
