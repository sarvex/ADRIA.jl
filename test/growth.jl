using Test
using Distributions
using ADRIA

@testset "Coral Spec" begin

    linear_extension = Array{Float64,2}([
        1 3 3 4.4 4.4 4.4   # Tabular Acropora Enhanced
        1 3 3 4.4 4.4 4.4   # Tabular Acropora Unenhanced
        1 3 3 3 3 3         # Corymbose Acropora Enhanced
        1 3 3 3 3 3         # Corymbose Acropora Unenhanced
        1 1 1 1 0.8 0.8     # small massives
        1 1 1 1 1.2 1.2])   # large massives

    bin_widths = Float64[2, 3, 5, 10, 20, 40]'  # These bin widths have to line up with values in colony_areas()

    growth_rates = (2 * linear_extension) ./ bin_widths  # growth rates as calculated without growth_rate(), maintaining species x size_class structure
    # growth_rates[:, 6] .= 0.8 * growth_rates[:, 6]

    mb = Array{Float64,2}([
        0.2 0.2 0.19 0.19 0.098 0.098    # Tabular Acropora Enhanced
        0.2 0.2 0.19 0.19 0.098 0.098    # Tabular Acropora Unenhanced
        0.2 0.2 0.172 0.172 0.088 0.088    # Corymbose Acropora Enhanced
        0.2 0.2 0.172 0.172 0.088 0.088    # Corymbose Acropora Unenhanced
        0.2 0.2 0.04 0.04 0.02 0.02    # Small massives and encrusting
        0.2 0.2 0.04 0.04 0.02 0.02])   # Large massives

    bleaching_sensitivity = Float64[
        1.40 1.40 1.40 1.40 1.40 1.40  # Tabular Acropora Enhanced (assumed same as Corymbose)
        1.40 1.40 1.40 1.40 1.40 1.40  # Tabular Acropora Unenhanced
        1.40 1.40 1.40 1.40 1.40 1.40  # Corymbose Acropora Enhanced
        1.40 1.40 1.40 1.40 1.40 1.40  # Corymbose Acropora Unenhanced
        0.25 0.25 0.25 0.25 0.25 0.25  # Small massives and encrusting
        0.25 0.25 0.25 0.25 0.25 0.25] # Large massives

    coral_params = ADRIA.coral_spec().params
    stored_growth_rate = coral_params.growth_rate
    stored_mb_rate = coral_params.mb_rate
    stored_bleaching_sensitivity = coral_params.bleaching_sensitivity

    # check each size class parameter matches that stored for it's size class
    for i = 1:6
        @test all(stored_growth_rate[coral_params.class_id.==i] .== growth_rates[:, i]) || "Growth rates incorrect for size class $i ."

        @test all(stored_mb_rate[coral_params.class_id.==i] .== mb[:, i]) || "Background mortality rates incorrect for size class $i."

        @test all(stored_bleaching_sensitivity[coral_params.class_id.==i] .== bleaching_sensitivity[:, i]) || "Bleaching sensitivity incorrect for size class $i."
    end

    # check all growth rates are <=1 and >0
    # @test all(stored_growth_rate .<= 1.0) || "Some coral growth rates are >1."
    @test all(stored_growth_rate .> 0.0) || "Some coral growth rates are <=0"

    # check all background mortalities are <=1 and >0
    @test all(stored_mb_rate .<= 1.0) || "Some coral background mortality rates are >1."
    @test all(stored_mb_rate .> 0.0) || "Some coral background mortality rates are <=0"

    # check coral mortalities and growth rates decrease with increasing size class
    for j = 1:5
        # @test all(stored_growth_rate[coral_params.class_id.==j] .>= stored_growth_rate[coral_params.class_id.==j+1]) || "Growth rates for size class $j is less than that for size class $(j + 1)."
        @test all(stored_mb_rate[coral_params.class_id.==j] .>= stored_mb_rate[coral_params.class_id.==j+1]) || "Background mortality rates for size class $j is less than that for size class $(j + 1)."
    end

    bin_edges_cm = [0, 2, 5, 10, 20, 40, 80]
    bin_edge_diameters_cm2 = pi .* (bin_edges_cm ./ 2) .^ 2
    stored_colony_mean_areas = coral_params.colony_area_cm2

    # check colony areas in cm^2 are within bounds designated by bin edges
    for k = 1:6
        @test all(stored_colony_mean_areas[coral_params.class_id.==k] .>= bin_edge_diameters_cm2[k]) || "Some colony areas for size class $k are larger than the size class upper bound."
        @test all(stored_colony_mean_areas[coral_params.class_id.==k] .>= bin_edge_diameters_cm2[k]) || "Some colony areas for size class $k are smaller than the size class lower bound."
    end
end

@testset "Fecundity" begin
    fec_groups = zeros(6, 216)
    fec_all = zeros(36, 216)
    fec_params = [25281.51645394548, 50989.55542425965, 78133.52681199001, 115189.85341730568,
        169820.8550374081, 250361.6590357049, 25281.51645394548, 50989.55542425965,
        78133.52681199001, 115189.85341730568, 169820.8550374081, 250361.6590357049,
        52228.76428701259, 59199.29777746337, 63887.49751239493, 68472.9244216383,
        73387.46329736525, 78654.73564497223, 52228.76428701259, 59199.29777746337,
        63887.49751239493, 68472.9244216383, 73387.46329736525, 78654.73564497223,
        21910.874521191126, 37082.43894786883, 51072.30305499843, 68331.04154366927,
        91421.98332850973, 122315.9906084096, 21910.874521191126, 37082.43894786883,
        51072.30305499843, 68331.04154366927, 91421.98332850973, 122315.9906084096]

    Y_pstep = rand(Uniform(0.0, 0.01), 36, 216)
    total_site_area = [76997.8201778261, 38180.997513339855, 334269.6228868989, 70728.59381575836, 48824.963081851136, 87942.62072634231, 57278.82204914279, 131481.403591529, 90463.151137474, 42261.42923473893, 312.98931139567867, 57605.03185068816, 60083.839003962465, 54785.65416847123, 12832.631625673268, 76044.65694113867, 100181.29909620434, 118024.50294493232, 60109.49596805731, 242250.00915593235, 124908.22948251851, 113635.26297052717, 91707.8292375924, 135850.1470950297, 49141.425121693406, 53826.22338320641, 97025.1128987968, 68525.34328866098, 148695.41590357665, 28781.728845587466, 165585.33163399575, 23778.652445240412, 16592.14594898885, 158322.37248498667, 118921.10221339483, 128982.22331511462, 107034.72890100488, 86652.49363158084, 158343.6427825936, 5318.305293030571, 9389.681316065602, 3129.26198370615, 135152.96035117377, 23472.247369048186, 97606.50613648817, 71946.8830838264, 35981.50364708854, 28797.393418124877, 29107.717398312874, 53826.99441838125, 311336.2225115001, 125505.64010765497, 99856.55065180548, 106090.00433640555, 180018.80202134652, 326071.049694587, 190216.44162023207, 53827.47156010475, 144629.18991992064, 148898.01095200004, 96661.44398395158, 290148.5026182546, 114825.04259502981, 140754.4730709605, 68829.15950475587, 95473.48294012994, 81080.31676690746, 169308.24664905109, 114162.37943328498, 22536.31970276218, 48824.50477898354, 64804.19810403744, 162433.71505506802, 51000.481316191144, 150484.32479333598, 46612.03379469784, 134619.66478604497, 54461.06710961368, 107594.00013558939, 40370.00313273119, 62282.677392093, 111411.61847271444, 148083.46177229844, 234284.18705729162, 96100.27528847847, 63184.710597992875, 103282.46208330011, 126132.27669022558, 51333.54014409892, 41937.25823739078, 70105.24495933158, 66337.72066151444, 100498.80730765127, 22524.106860139407, 335968.1465102434, 23157.07392614428, 64115.71150727989, 43187.80882960232, 55396.315229838714, 322942.3789655925, 264867.9285628754, 233662.25014557084, 134911.29212181736, 90572.83054631483, 48411.07756591868, 87456.35002980288, 369127.91149331676, 252347.31258559506, 231125.33238760522, 114617.7986012646, 1561.3605366628617, 133976.43868495245, 177710.91558774887, 261426.5130989817, 233946.98499754444, 14987.148259407375, 68075.72698056, 69341.32427705498, 129437.48085331544, 76901.33963279286, 111941.78706551343, 78184.30865436653, 98454.09477984346, 52201.226116100326, 62855.21237831516, 124458.66966792708, 24079.841552573256, 111959.48772720806, 22512.65185918659, 74701.63197803684, 124114.03316707956, 80338.79890576331, 41584.86461727973, 38441.346766835544, 136971.89531025803, 167229.85133617045, 140734.54589663213, 184158.822707986, 33770.755155074876, 17826.207357996143, 1250.9943127147853, 101592.19755722815, 122570.48372718506, 249215.26396020036, 183567.23185554985, 118473.36072853673, 84114.7206080337, 252338.2882249197, 104395.61599875009, 287106.2325030188, 248588.7888734066, 139489.46534616407, 109694.42252342962, 226140.37395826913, 129389.22499938775, 185781.30174259283, 106306.2538784002, 159193.62830397952, 104134.67320310418, 86911.49756977474, 348115.2531043119, 47815.115320474375, 190386.1996394787, 221756.60024294443, 106927.86914726766,
        89753.67927749828, 299004.6593301678, 124114.19568072166, 120039.92525529955, 219873.910698622, 77874.03697757702, 187571.9804283902, 58788.913771106396, 304977.0016628909, 54074.51778317196, 75350.34206689568, 69390.57800343214, 232402.37505759858, 126950.81416913401, 19064.742817895487, 25021.277749726083, 14695.997722434346, 170774.58696733043, 625.2096516690217, 130026.698200766, 205455.53109697672, 63153.77036182955, 137544.44021125184, 107886.94441078696, 85240.40940979542, 142395.81966814818, 60271.87516689906, 26857.034316257108, 20922.45744012855, 226991.3332164348, 142089.56898094108, 54014.206533902325, 144895.9872502829, 108356.8193304576, 29666.78814761853, 27475.359576036688, 936.6064325589687, 20608.68716322258, 47156.65406070184, 70263.70212964155, 122069.65583620407, 9989.258782846853, 48092.119152385276, 61209.73700846825, 189495.98940768326, 233534.96450603567, 186725.16725444607, 140815.23524318123, 60269.32989888545, 51815.93369295262, 49022.921055841725]

    ADRIA.fecundity_scope!(fec_groups, fec_all, fec_params, Y_pstep, Matrix(total_site_area'))

    @test any(fec_groups .> 1e8) || "Fecundity is measured in m² and so should be a very large number"
    @test !any(fec_groups .< 0.0) || "Negative fecundity is not allowed"
end

@testset "Larval Production" begin
    tstep = 2
    a_adapt = fill(4.0, 36)
    n_adapt = 0.025
    dhw_scen = fill(4.0, 50)
    LPdhwcoeff = 0.4
    DHWmaxtot = 50.0
    LPDprm2 = 5.0
    n_groups = 6

    LPs = ADRIA.stressed_fecundity(tstep, a_adapt, n_adapt, dhw_scen[tstep-1, :],
        LPdhwcoeff, DHWmaxtot, LPDprm2, n_groups)
    @test all(0.0 .<= LPs .< 1.0) || "Larval Production must be between 0 and 1"
end

@testset "Recruitment" begin
    total_site_area = [76997.8201778261, 38180.997513339855, 334269.6228868989, 70728.59381575836, 48824.963081851136, 87942.62072634231, 57278.82204914279, 131481.403591529, 90463.151137474, 42261.42923473893, 312.98931139567867, 57605.03185068816, 60083.839003962465, 54785.65416847123, 12832.631625673268, 76044.65694113867, 100181.29909620434, 118024.50294493232, 60109.49596805731, 242250.00915593235, 124908.22948251851, 113635.26297052717, 91707.8292375924, 135850.1470950297, 49141.425121693406, 53826.22338320641, 97025.1128987968, 68525.34328866098, 148695.41590357665, 28781.728845587466, 165585.33163399575, 23778.652445240412, 16592.14594898885, 158322.37248498667, 118921.10221339483, 128982.22331511462, 107034.72890100488, 86652.49363158084, 158343.6427825936, 5318.305293030571, 9389.681316065602, 3129.26198370615, 135152.96035117377, 23472.247369048186, 97606.50613648817, 71946.8830838264, 35981.50364708854, 28797.393418124877, 29107.717398312874, 53826.99441838125, 311336.2225115001, 125505.64010765497, 99856.55065180548, 106090.00433640555, 180018.80202134652, 326071.049694587, 190216.44162023207, 53827.47156010475, 144629.18991992064, 148898.01095200004, 96661.44398395158, 290148.5026182546, 114825.04259502981, 140754.4730709605, 68829.15950475587, 95473.48294012994, 81080.31676690746, 169308.24664905109, 114162.37943328498, 22536.31970276218, 48824.50477898354, 64804.19810403744, 162433.71505506802, 51000.481316191144, 150484.32479333598, 46612.03379469784, 134619.66478604497, 54461.06710961368, 107594.00013558939, 40370.00313273119, 62282.677392093, 111411.61847271444, 148083.46177229844, 234284.18705729162, 96100.27528847847, 63184.710597992875, 103282.46208330011, 126132.27669022558, 51333.54014409892, 41937.25823739078, 70105.24495933158, 66337.72066151444, 100498.80730765127, 22524.106860139407, 335968.1465102434, 23157.07392614428, 64115.71150727989, 43187.80882960232, 55396.315229838714, 322942.3789655925, 264867.9285628754, 233662.25014557084, 134911.29212181736, 90572.83054631483, 48411.07756591868, 87456.35002980288, 369127.91149331676, 252347.31258559506, 231125.33238760522, 114617.7986012646, 1561.3605366628617, 133976.43868495245, 177710.91558774887, 261426.5130989817, 233946.98499754444, 14987.148259407375, 68075.72698056, 69341.32427705498, 129437.48085331544, 76901.33963279286, 111941.78706551343, 78184.30865436653, 98454.09477984346, 52201.226116100326, 62855.21237831516, 124458.66966792708, 24079.841552573256, 111959.48772720806, 22512.65185918659, 74701.63197803684, 124114.03316707956, 80338.79890576331, 41584.86461727973, 38441.346766835544, 136971.89531025803, 167229.85133617045, 140734.54589663213, 184158.822707986, 33770.755155074876, 17826.207357996143, 1250.9943127147853, 101592.19755722815, 122570.48372718506, 249215.26396020036, 183567.23185554985, 118473.36072853673, 84114.7206080337, 252338.2882249197, 104395.61599875009, 287106.2325030188, 248588.7888734066, 139489.46534616407, 109694.42252342962, 226140.37395826913, 129389.22499938775, 185781.30174259283, 106306.2538784002, 159193.62830397952, 104134.67320310418, 86911.49756977474, 348115.2531043119, 47815.115320474375, 190386.1996394787, 221756.60024294443, 106927.86914726766,
        89753.67927749828, 299004.6593301678, 124114.19568072166, 120039.92525529955, 219873.910698622, 77874.03697757702, 187571.9804283902, 58788.913771106396, 304977.0016628909, 54074.51778317196, 75350.34206689568, 69390.57800343214, 232402.37505759858, 126950.81416913401, 19064.742817895487, 25021.277749726083, 14695.997722434346, 170774.58696733043, 625.2096516690217, 130026.698200766, 205455.53109697672, 63153.77036182955, 137544.44021125184, 107886.94441078696, 85240.40940979542, 142395.81966814818, 60271.87516689906, 26857.034316257108, 20922.45744012855, 226991.3332164348, 142089.56898094108, 54014.206533902325, 144895.9872502829, 108356.8193304576, 29666.78814761853, 27475.359576036688, 936.6064325589687, 20608.68716322258, 47156.65406070184, 70263.70212964155, 122069.65583620407, 9989.258782846853, 48092.119152385276, 61209.73700846825, 189495.98940768326, 233534.96450603567, 186725.16725444607, 140815.23524318123, 60269.32989888545, 51815.93369295262, 49022.921055841725]

    max_cover = [0.7994791666666667, 0.8281954887218045, 0.7851667141635794, 0.4471883468834688, 0.2682038834951456, 0.22582799145299146, 0.37644557823129254, 0.8256137184115522, 0.8128955696202531, 0.7958333333333333, 0.79375, 0.8109090909090909, 0.8421974522292993, 0.8400943396226416, 0.9555147058823528, 0.8261519302615192, 0.7543560606060606, 0.8048672566371681, 0.8674960505529227, 0.8668855350842807, 0.8285714285714285, 0.7276800670016751, 0.8946483971044468, 0.7942642956764294, 0.8401061776061777, 0.8349199288256227, 0.7973046488625124, 0.7484375, 0.8597701149425288, 0.738157894736842, 0.787012614678899, 0.8234063745019919, 0.6195402298850575, 0.813600958657879, 0.8494608626198084, 0.8348451327433628, 0.8488475177304964, 0.707681718061674, 0.09557495484647802, 0.49772727272727274, 0.0, 0.1671875, 0.13639887244538407, 0.3606275303643725, 0.3607281553398058, 0.3238486842105263, 0.29787798408488064, 0.19801980198019803, 0.04226384364820847, 0.05091463414634147, 0.14856181150550796, 0.031401975683890575, 0.3209043560606061, 0.07855545617173525, 0.2498151082937137, 0.1478245052386496, 0.01662067235323633, 0.3466312056737588, 0.2612516425755585, 0.0, 0.06648514851485149, 0.4162282144031568, 0.21659053156146174, 0.0, 0.06990358126721763, 0.0, 0.2652972027972028, 0.09807367829021371, 0.06629260182876143, 0.0, 0.2735756385068762, 0.25421597633136095, 0.11000585137507315, 0.45347091932457784, 0.21974921630094044, 0.0029531568228105907, 0.1417079207920792, 0.33893728222996516, 0.01978433098591549, 0.3768912529550827, 0.09308510638297872, 0.012298558100084818, 0.23876368319381844, 0.2072485806974858, 0.2395771144278607, 0.030322338830584706, 0.04146678966789667, 0.15478080120937265, 0.3972326454033771, 0.45033936651583706, 0.023770491803278684, 0.42984330484330485, 0.2326283269961977, 0.018510638297872337, 0.0028753541076487255, 0.38378661087866106, 0.1761177347242921, 0.0, 0.0, 0.05571996466431095, 0.203753591954023, 0.002945956928078017, 0.7844985875706213, 0.817434554973822, 0.8347847358121331, 0.816866158868335, 0.7743100335310806, 0.8051132075471699, 0.8402451586320561, 0.8425895087427143, 0.153125, 0.5157361308677099, 0.4184415236051502, 0.440201096892139, 0.4233644859813085, 0.0, 0.6383356545961003, 0.49203448275862066, 0.836398678414097, 0.7965217391304347, 0.8352803738317758, 0.7639570552147239, 0.7740310077519379, 0.8151556776556776, 0.7917170953101363, 0.8607006125574272, 0.7628968253968255, 0.7581218274111676, 0.8317510548523207, 0.8651524777636596, 0.8587729357798166, 0.8918831168831168, 0.8416856492027336, 0.8058024691358024, 0.8590292275574113, 0.8536505681818182, 0.8108108108108109, 0.19772609819121445, 0.008403361344537815, 0.33973684210526317, 0.0, 0.24309366130558183, 0.3985190958690569, 0.22419324577861166, 0.2526859504132231, 0.05810111464968152, 0.221408371040724, 0.15699404761904762, 0.23008707607699358, 0.21485411140583555, 0.2998139188686267, 0.1087782340862423, 0.49505662020905916, 0.0, 0.5137171286425017, 0.18438139059304703, 0.13609374999999999, 0.1288519184652278, 0.19422901459854014, 0.2702680525164114, 0.13843477074235808, 0.32840909090909093, 0.07080620931397096, 0.0, 0.07355427046263345, 0.15397970085470086, 0.10110654441985456, 0.2427227342549923, 0.30559055118110234, 0.15022697795071335, 0.10296454767726161, 0.1523560876209883, 0.09530228758169935, 0.0, 0.44330122591943955, 0.23238065326633164, 0.4743430152143845, 0.0, 0.3148912228057014, 0.003553921568627451, 0.022568093385214007, 0.6845779220779221, 0.2073331463825014, 0.0, 0.1653196179279941, 0.45164066085360255, 0.0993609022556391, 0.15223492723492724, 0.30090388007054675, 0.7516722408026756, 0.7767453457446807, 0.8221608832807571, 0.7635714285714286, 0.7432870370370369, 0.7922268907563026, 0.7657868190988566, 0.6909649122807018, 0.8549475753604194, 0.8318340611353712, 0.16432038834951457, 0.5296167247386759, 0.445, 0.19621559633027524, 0.31793699186991864, 0.5947798295454545, 0.27817398119122255, 0.11778846153846154, 0.22971230158730158, 0.26975931677018633, 0.1465971873430437, 0.3727911237785016, 0.16538167938931295, 0.17808912896691426, 0.2891167192429022, 0.26555555555555554, 0.5870553359683794]

    avail_area = rand(1, 216)

    larval_pool = rand(1.0:5e11, 6, 216)

    recruits_per_m² = ADRIA.recruitment(larval_pool, avail_area)
    abs_recruits = recruits_per_m² .* (avail_area' .* max_cover .* total_site_area)'

    @test any(abs_recruits .> 10^4) || "At least some recruitment values should be > 10,000"

    theoretical_max = ((avail_area' .* max_cover .* total_site_area)' * 51.8)
    for (i, rec) in enumerate(eachrow(abs_recruits))
        @test all(rec' .<= theoretical_max) || "Species group $i exceeded maximum theoretical number of settlers"
    end
end


@testset "growth model" begin
    here = @__DIR__
    dom = ADRIA.load_domain(joinpath(here, "../examples/Example_domain"), "45")
    n_sites = size(dom.site_data)[1]
    p = dom.coral_growth.ode_p

    du = zeros(36, n_sites)
    absolute_k_area = rand(1e3:1e6, 1, n_sites)
    total_site_area = rand(1e4:2.5e6, 1, n_sites)
    cover_tmp = zeros(n_sites)
    max_cover = min.(vec(absolute_k_area ./ total_site_area), 0.5)

    # Test magnitude of change are within bounds
    Y_cover = zeros(2, 36, n_sites)
    population = rand(1e3:1e6, 36, n_sites)
    Y_cover[1, :, :] = population ./ total_site_area
    ADRIA.proportional_adjustment!(Y_cover[1, :, :], cover_tmp, max_cover)
    growthODE(du, Y_cover[1, :, :], p, 1)
    @test !any(abs.(du) .> 1.0) || "growth function is producing inappropriate values (abs(du) > 1.0)"

    # Test zero recruit and coverage conditions
    Y_cover = zeros(2, 36, n_sites)
    p.rec .= zeros(6, n_sites)
    growthODE(du, Y_cover[1, :, :], p, 1)
    @test all(du .== 0.0) || "Growth produces non-zero values with zero recuitment and zero initial cover."

    # Test direction and magnitude of change
    p.rec .= rand(0:0.001:0.5, 6, n_sites)
    Y_cover = zeros(10, 36, n_sites)
    Y_cover[1, :, :] = rand(1e3:1e6, 36, n_sites)
    ADRIA.proportional_adjustment!(Y_cover[1, :, :], cover_tmp, max_cover)
    for tstep = 2:10
        growthODE(du, Y_cover[tstep-1, :, :], p, 1)
        Y_cover[tstep, :, :] .= Y_cover[tstep-1, :, :] .+ du
        ADRIA.proportional_adjustment!(Y_cover[tstep, :, :], cover_tmp, max_cover)
    end
    @test any(diff(Y_cover, dims=1) .< 0) || "ODE never decreases, du being restricted to >=0."
    @test any(diff(Y_cover, dims=1) .>= 0) || "ODE never increases, du being restricted to <=0."
    @test all(abs.(diff(Y_cover, dims=1)) .< 1.0) || "ODE more than doubles or halves area."


    # Test change in smallest size class under no recruitment
    p.rec .= zeros(6, n_sites)
    Y_cover = zeros(10, 36, n_sites)
    Y_cover[1, :, :] = rand(1e3:1e6, 36, n_sites)
    ADRIA.proportional_adjustment!(Y_cover[1, :, :], cover_tmp, max_cover)
    for tstep = 2:10
        growthODE(du, Y_cover[tstep-1, :, :], p, 1)
        Y_cover[tstep, :, :] .= Y_cover[tstep-1, :, :] .+ du
        ADRIA.proportional_adjustment!(Y_cover[tstep, :, :], cover_tmp, max_cover)
    end
    @test all((diff(Y_cover[:, [1, 7, 13, 19, 25, 31], :], dims=1) .<= 0)) || "Smallest size class growing with no recruitment.."
end
