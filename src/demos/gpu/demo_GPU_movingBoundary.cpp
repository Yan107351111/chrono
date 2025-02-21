// =============================================================================
// PROJECT CHRONO - http://projectchrono.org
//
// Copyright (c) 2019 projectchrono.org
// All rights reserved.
//
// Use of this source code is governed by a BSD-style license that can be found
// in the LICENSE file at the top level of the distribution and at
// http://projectchrono.org/license-chrono.txt.
//
// =============================================================================
// Authors: Conlain Kelly
// =============================================================================
// Chrono::Gpu simulation of a rectangular bed of granular material which
// is first let to settle and then compressed by advancing one of the box walls
// into the material.
// =============================================================================

#include <iostream>
#include <string>
#include <cmath>

#include "chrono/utils/ChUtilsSamplers.h"

#include "chrono_gpu/physics/ChSystemGpu.h"
#include "chrono_gpu/utils/ChGpuJsonParser.h"

#include "chrono_thirdparty/filesystem/path.h"

using namespace chrono;
using namespace chrono::gpu;

// -----------------------------------------------------------------------------
// Show command line usage
// -----------------------------------------------------------------------------
void ShowUsage(std::string name) {
    std::cout << "usage: " + name + " <json_file>" << std::endl;
}

int main(int argc, char* argv[]) {
    ChGpuSimulationParameters params;

    // Some of the default values might be overwritten by user via command line
    if (argc != 2 || ParseJSON(argv[1], params) == false) {
        ShowUsage(argv[0]);
        return 1;
    }

    // Setup simulation
    ChSystemGpu gpu_sys(params.sphere_radius, params.sphere_density,
                        make_float3(params.box_X, params.box_Y, params.box_Z));

    gpu_sys.SetPsiFactors(params.psi_T, params.psi_L);

    gpu_sys.SetKn_SPH2SPH(params.normalStiffS2S);
    gpu_sys.SetKn_SPH2WALL(params.normalStiffS2W);
    gpu_sys.SetGn_SPH2SPH(params.normalDampS2S);
    gpu_sys.SetGn_SPH2WALL(params.normalDampS2W);

    gpu_sys.SetKt_SPH2SPH(params.tangentStiffS2S);
    gpu_sys.SetKt_SPH2WALL(params.tangentStiffS2W);
    gpu_sys.SetGt_SPH2SPH(params.tangentDampS2S);
    gpu_sys.SetGt_SPH2WALL(params.tangentDampS2W);
    gpu_sys.SetStaticFrictionCoeff_SPH2SPH(params.static_friction_coeffS2S);
    gpu_sys.SetStaticFrictionCoeff_SPH2WALL(params.static_friction_coeffS2W);

    gpu_sys.SetCohesionRatio(params.cohesion_ratio);
    gpu_sys.SetAdhesionRatio_SPH2WALL(params.adhesion_ratio_s2w);

    gpu_sys.SetGravitationalAcceleration(ChVector<float>(params.grav_X, params.grav_Y, params.grav_Z));
    gpu_sys.SetOutputMode(params.write_mode);

    filesystem::create_directory(filesystem::path(params.output_dir));

    // fill box, layer by layer
    ChVector<float> hdims((float)(params.box_X / 2.0 - 1.2), (float)(params.box_Y / 2.0 - 1.2),
                          (float)(params.box_Z / 10.0 - 1.2));
    ChVector<float> center(0.f, 0.f, (float)(-params.box_Z / 2.0 + params.box_Z / 10.0));

    // Fill box with bodies
    std::vector<ChVector<float>> body_points =
        utils::PDLayerSampler_BOX<float>(center, hdims, 2.f * params.sphere_radius, 1.05f);

    gpu_sys.SetParticlePositions(body_points);

    // Set the position of the BD
    gpu_sys.SetBDFixed(true);

    gpu_sys.SetTimeIntegrator(CHGPU_TIME_INTEGRATOR::FORWARD_EULER);
    gpu_sys.SetFrictionMode(CHGPU_FRICTION_MODE::MULTI_STEP);
    gpu_sys.SetFixedStepSize(params.step_size);

    gpu_sys.SetVerbosity(params.verbose);

    // start outside BD by 10 cm
    ChVector<float> plane_pos(-params.box_X / 2 - 10, 0, 0);
    ChVector<float> plane_normal(1, 0, 0);

    size_t plane_bc_id = gpu_sys.CreateBCPlane(plane_pos, plane_normal, false);

    // Function prescibing the motion of the advancing plane.
    // Begins outside of the domain.
    std::function<double3(float)> plane_pos_func = [&params](float t) {
        double3 pos = {0, 0, 0};

        // move at 10 cm/s
        constexpr float vel = 10;

        // after 1 second the plane will be at the edge of the BD, and will continue in thereafter
        pos.x = vel * t;

        return pos;
    };

    gpu_sys.Initialize();

    gpu_sys.SetBCOffsetFunction(plane_bc_id, plane_pos_func);

    int fps = 50;
    // assume we run for at least one frame
    float frame_step = 1.0f / fps;
    float curr_time = 0;
    int currframe = 0;
    unsigned int total_frames = (unsigned int)((float)params.time_end * fps);

    char filename[100];
    sprintf(filename, "%s/step%06d", params.output_dir.c_str(), currframe++);
    gpu_sys.WriteFile(std::string(filename));

    std::cout << "frame step is " << frame_step << std::endl;

    // Run settling experiments
    while (curr_time < params.time_end) {
        gpu_sys.AdvanceSimulation(frame_step);
        curr_time += frame_step;
        printf("rendering frame %u of %u\n", currframe, total_frames);
        char filename[100];
        sprintf(filename, "%s/step%06d", params.output_dir.c_str(), currframe++);
        gpu_sys.WriteFile(std::string(filename));
    }

    return 0;
}
