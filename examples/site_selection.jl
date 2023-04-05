using ADRIA: run_site_selection, ranks_to_frequencies
using NamedDims


@info "Loading data package"
here = @__DIR__
dom = ADRIA.load_domain(joinpath(here, "Moore_2022-11-17"), "45")

criteria_df = ADRIA.sample_site_selection(dom, 2^8) # get scenario dataframe

area_to_seed = 962.11  # area of seeded corals in m^2

# define functions for tolerances
f_coral_cover(param) = area_to_seed * param

coral_cover = NamedDims.rename(repeat(sum(dom.init_coral_cover, dims=:species), size(criteria_df, 1)), (:scenarios, :locations))
# initial coral cover matching number of criteria samples (size = (no. criteria scens, no. of sites))
tolerances = (iv__coral_cover=(>, x -> f_coral_cover(x)),
    iv__heat_stress=(<, x -> x),
    iv__wave_stress=(<, x -> x))

ranks, rank_frequencies = run_site_selection(dom, criteria_df, tolerances, coral_cover', aggregation_method=[ranks_to_frequencies, "seed"])
