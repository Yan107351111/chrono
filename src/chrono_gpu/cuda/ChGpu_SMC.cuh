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
// Holds internal functions and kernels for running a sphere-sphere timestep
//
// =============================================================================
// Contributors: Conlain Kelly, Nic Olsen, Dan Negrut
// =============================================================================

#pragma once

#include "chrono_thirdparty/cub/cub.cuh"

#include <cuda.h>
#include <cassert>
#include <cstdio>
#include <fstream>
#include <ios>
#include <iostream>
#include <sstream>
#include <string>
#include <cstdint>

#include "chrono_gpu/ChGpuDefines.h"
#include "chrono_gpu/physics/ChSystemGpu_impl.h"
#include "chrono_gpu/cuda/ChCudaMathUtils.cuh"
#include "chrono_gpu/cuda/ChGpuHelpers.cuh"
#include "chrono_gpu/cuda/ChGpuBoundaryConditions.cuh"

using chrono::gpu::ChSystemGpu_impl;

using chrono::gpu::CHGPU_TIME_INTEGRATOR;
using chrono::gpu::CHGPU_FRICTION_MODE;
using chrono::gpu::CHGPU_ROLLING_MODE;

/// @addtogroup gpu_cuda
/// @{

/// Convert position from its owner subdomain local frame to the global big domain frame
inline __device__ __host__ int64_t3 convertPosLocalToGlobal(unsigned int ownerSD,
                                                            const int3& local_pos,
                                                            ChSystemGpu_impl::GranParamsPtr gran_params) {
    int3 ownerSD_triplet = SDIDTriplet(ownerSD, gran_params);
    int64_t3 sphPos_global = {0, 0, 0};

    sphPos_global.x = ((int64_t)ownerSD_triplet.x) * gran_params->SD_size_X_SU + gran_params->BD_frame_X;
    sphPos_global.y = ((int64_t)ownerSD_triplet.y) * gran_params->SD_size_Y_SU + gran_params->BD_frame_Y;
    sphPos_global.z = ((int64_t)ownerSD_triplet.z) * gran_params->SD_size_Z_SU + gran_params->BD_frame_Z;

    sphPos_global.x += (int64_t)local_pos.x;
    sphPos_global.y += (int64_t)local_pos.y;
    sphPos_global.z += (int64_t)local_pos.z;
    return sphPos_global;
}

/// Takes in a sphere's position and inserts into the given int array[8] which subdomains, if any, are touched
/// The array is indexed with the ones bit equal to +/- x, twos bit equal to +/- y, and the fours bit equal to +/- z
/// A bit set to 0 means the lower index, whereas 1 means the higher index (lower + 1)
/// The kernel computes global x, y, and z indices for the bottom-left subdomain and then uses those to figure out
/// which subdomains described in the corresponding 8-SD cube are touched by the sphere. The kernel then converts
/// these indices to indices into the global SD list via the (currently local) conv[3] data structure Should be
/// mostly bug-free, especially away from boundaries
inline __device__ void figureOutTouchedSD(int64_t sphCenter_X_relative,
                                          int64_t sphCenter_Y_relative,
                                          int64_t sphCenter_Z_relative,
                                          unsigned int SDs[MAX_SDs_TOUCHED_BY_SPHERE],
                                          ChSystemGpu_impl::GranParamsPtr gran_params) {
    // grab radius as signed so we can use it intelligently
    const signed int sphereRadius_SU = gran_params->sphereRadius_SU;
    // I added these to fix a bug, we can inline them if/when needed but they ARE necessary
    // We need to offset so that the bottom-left corner is at the origin

    // TODO this should never be over 2 billion anyways
    signed int nx[2], ny[2], nz[2];

    // get the bottom-left-most SD that the particle touches
    // nx = (xCenter - radius) / wx
    nx[0] = (signed int)((sphCenter_X_relative - sphereRadius_SU) / gran_params->SD_size_X_SU);
    // Same for Y and Z
    ny[0] = (signed int)((sphCenter_Y_relative - sphereRadius_SU) / gran_params->SD_size_Y_SU);
    nz[0] = (signed int)((sphCenter_Z_relative - sphereRadius_SU) / gran_params->SD_size_Z_SU);

    // get the top-right-most SD that the particle touches
    nx[1] = (signed int)((sphCenter_X_relative + sphereRadius_SU) / gran_params->SD_size_X_SU);
    ny[1] = (signed int)((sphCenter_Y_relative + sphereRadius_SU) / gran_params->SD_size_Y_SU);
    nz[1] = (signed int)((sphCenter_Z_relative + sphereRadius_SU) / gran_params->SD_size_Z_SU);
    // figure out what
    // number of iterations in each direction
    int num_x = (nx[0] == nx[1]) ? 1 : 2;
    int num_y = (ny[0] == ny[1]) ? 1 : 2;
    int num_z = (nz[0] == nz[1]) ? 1 : 2;

    // TODO unroll me
    for (int i = 0; i < num_x; i++) {
        for (int j = 0; j < num_y; j++) {
            for (int k = 0; k < num_z; k++) {
                // composite index to write to
                int id = i * 4 + j * 2 + k;
                // if I ran out of the box, give up and set this to NULL
                if ((nx[i] < 0 || nx[i] >= gran_params->nSDs_X) || (ny[j] < 0 || ny[j] >= gran_params->nSDs_Y) ||
                    (nz[k] < 0 || nz[k] >= gran_params->nSDs_Z)) {
                    SDs[id] = NULL_CHGPU_ID;
                    continue;  // skip this SD
                }

                // ok so now this SD id is ok, carry on
                SDs[id] = nx[i] * gran_params->nSDs_Y * gran_params->nSDs_Z + ny[j] * gran_params->nSDs_Z + nz[k];
            }
        }
    }
}

/**
 * This kernel call prepares information that will be used in a subsequent kernel that performs the actual time
 * stepping.
 *
 * Template arguments:
 *   - CUB_THREADS: the number of threads used in this kernel, comes into play when invoking CUB block collectives
 *
 * Assumptions:
 *   - Granular material is made up of monodisperse spheres.
 *   - The function below assumes the spheres are in a box
 *   - The box has dimensions L x D x H.
 *   - The reference frame associated with the box:
 *       - The x-axis is along the length L of the box
 *       - The y-axis is along the width D of the box
 *       - The z-axis is along the height H of the box
 *   - A sphere cannot touch more than eight SDs
 *
 * Basic idea: use domain decomposition on the rectangular box and figure out how many SDs each sphere touches.
 * The subdomains are axis-aligned relative to the reference frame associated with the *box*. The origin of the box is
 * at the center of the box. The orientation of the box is defined relative to a world inertial reference frame.
 *
 * Nomenclature:
 *   - SD: subdomain.
 *   - BD: the big-domain, which is the union of all SDs
 *   - NULL_CHGPU_ID: the equivalent of a non-sphere SD ID, or a non-sphere ID
 *
 * Notes:
 *   - The SD with ID=0 is the catch-all SD. This is the SD in which a sphere ends up if its not inside the rectangular
 * box. Usually, there is no sphere in this SD (THIS IS NOT IMPLEMENTED AS SUCH FOR NOW)
 *
 */
template <unsigned int CUB_THREADS>  // Number of CUB threads engaged in block-collective CUB operations. Should be a
                                     // multiple of 32
__global__ void sphereBroadphase_dryrun(ChSystemGpu_impl::GranSphereDataPtr sphere_data,
                                        unsigned int nSpheres,  // Number of spheres in the box
                                        ChSystemGpu_impl::GranParamsPtr gran_params) {
    /// Set aside shared memory
    volatile __shared__ bool shMem_head_flags[CUB_THREADS * MAX_SDs_TOUCHED_BY_SPHERE];

    typedef cub::BlockRadixSort<unsigned int, CUB_THREADS, MAX_SDs_TOUCHED_BY_SPHERE> BlockRadixSortOP;
    __shared__ typename BlockRadixSortOP::TempStorage temp_storage_sort;

    typedef cub::BlockDiscontinuity<unsigned int, CUB_THREADS> Block_Discontinuity;
    __shared__ typename Block_Discontinuity::TempStorage temp_storage_disc;

    // Figure out what sphereID this thread will handle. We work with a 1D block structure and a 1D grid structure
    unsigned int mySphereID = threadIdx.x + blockIdx.x * blockDim.x;

    // This uses a lot of registers but is needed
    unsigned int SDsTouched[MAX_SDs_TOUCHED_BY_SPHERE] = {NULL_CHGPU_ID, NULL_CHGPU_ID, NULL_CHGPU_ID, NULL_CHGPU_ID,
                                                          NULL_CHGPU_ID, NULL_CHGPU_ID, NULL_CHGPU_ID, NULL_CHGPU_ID};
    if (mySphereID < nSpheres) {
        // Coalesced mem access
        int3 ownerSD_triplet = SDIDTriplet(sphere_data->sphere_owner_SDs[mySphereID], gran_params);
        // positions are relative to Big Domain corner
        int64_t sphere_pos_relative_X =
            ((int64_t)ownerSD_triplet.x) * gran_params->SD_size_X_SU + sphere_data->sphere_local_pos_X[mySphereID];
        int64_t sphere_pos_relative_Y =
            ((int64_t)ownerSD_triplet.y) * gran_params->SD_size_Y_SU + sphere_data->sphere_local_pos_Y[mySphereID];
        int64_t sphere_pos_relative_Z =
            ((int64_t)ownerSD_triplet.z) * gran_params->SD_size_Z_SU + sphere_data->sphere_local_pos_Z[mySphereID];

        // printf("relative pos is %lld, %lld, %lld\n", sphere_pos_relative_X, sphere_pos_relative_Y,
        //        sphere_pos_relative_Z);
        figureOutTouchedSD(sphere_pos_relative_X, sphere_pos_relative_Y, sphere_pos_relative_Z, SDsTouched,
                           gran_params);
    }

    __syncthreads();

    // Sort by the ID of the SD touched
    BlockRadixSortOP(temp_storage_sort).Sort(SDsTouched);
    __syncthreads();

    // Do a winningStreak search on whole block, might not have high utilization here
    bool head_flags[MAX_SDs_TOUCHED_BY_SPHERE];
    Block_Discontinuity(temp_storage_disc).FlagHeads(head_flags, SDsTouched, cub::Inequality());
    __syncthreads();

    // Write back to shared memory; eight-way bank conflicts here - to revisit later
    for (unsigned int i = 0; i < MAX_SDs_TOUCHED_BY_SPHERE; i++) {
        shMem_head_flags[MAX_SDs_TOUCHED_BY_SPHERE * threadIdx.x + i] = head_flags[i];
    }

    __syncthreads();

    // Count how many times an SD shows up in conjunction with the collection of CUB_THREADS spheres. There
    // will be some thread divergence here.
    // Loop through each potential SD, after sorting, and see if it is the start of a head
    for (unsigned int i = 0; i < MAX_SDs_TOUCHED_BY_SPHERE; i++) {
        // SD currently touched, could easily be inlined
        unsigned int touchedSD = SDsTouched[i];
        if (touchedSD != NULL_CHGPU_ID && head_flags[i]) {
            // current index into shared datastructure of length 8*CUB_THREADS, could easily be inlined
            unsigned int idInShared = MAX_SDs_TOUCHED_BY_SPHERE * threadIdx.x + i;
            unsigned int winningStreak = 0;  // should always be under 256 by simulation constraints
            // This is the beginning of a sequence of SDs with a new ID
            do {
                winningStreak++;
                // Go until we run out of threads on the warp or until we find a new head
            } while (idInShared + winningStreak < MAX_SDs_TOUCHED_BY_SPHERE * CUB_THREADS &&
                     !(shMem_head_flags[idInShared + winningStreak]));

            // Store start of new entries
            unsigned char sphere_offset = atomicAdd(sphere_data->SD_NumSpheresTouching + touchedSD, winningStreak);
        }
    }
}

/// Broadphase collision detection.
template <unsigned int CUB_THREADS>  // Number of CUB threads engaged in block-collective CUB operations. Should be a
                                     // multiple of 32
__global__ void sphereBroadphase(ChSystemGpu_impl::GranSphereDataPtr sphere_data,
                                 unsigned int nSpheres,  // Number of spheres in the box
                                 ChSystemGpu_impl::GranParamsPtr gran_params) {
    // Set aside shared memory
    // SD component of offset into composite array
    volatile __shared__ unsigned int sphere_composite_offsets[CUB_THREADS * MAX_SDs_TOUCHED_BY_SPHERE];
    volatile __shared__ bool shMem_head_flags[CUB_THREADS * MAX_SDs_TOUCHED_BY_SPHERE];

    typedef cub::BlockRadixSort<unsigned int, CUB_THREADS, MAX_SDs_TOUCHED_BY_SPHERE, unsigned int> BlockRadixSortOP;
    __shared__ typename BlockRadixSortOP::TempStorage temp_storage_sort;

    typedef cub::BlockDiscontinuity<unsigned int, CUB_THREADS> Block_Discontinuity;
    __shared__ typename Block_Discontinuity::TempStorage temp_storage_disc;

    // Figure out what sphereID this thread will handle. We work with a 1D block structure and a 1D grid structure
    unsigned int mySphereID = threadIdx.x + blockIdx.x * blockDim.x;
    unsigned int sphIDs[MAX_SDs_TOUCHED_BY_SPHERE] = {mySphereID, mySphereID, mySphereID, mySphereID,
                                                      mySphereID, mySphereID, mySphereID, mySphereID};

    // This uses a lot of registers but is needed
    unsigned int SDsTouched[MAX_SDs_TOUCHED_BY_SPHERE] = {NULL_CHGPU_ID, NULL_CHGPU_ID, NULL_CHGPU_ID, NULL_CHGPU_ID,
                                                          NULL_CHGPU_ID, NULL_CHGPU_ID, NULL_CHGPU_ID, NULL_CHGPU_ID};
    if (mySphereID < nSpheres) {
        // Coalesced mem access
        int3 ownerSD_triplet = SDIDTriplet(sphere_data->sphere_owner_SDs[mySphereID], gran_params);
        // positions are relative to Big Domain corner
        int64_t sphere_pos_relative_X =
            ((int64_t)ownerSD_triplet.x) * gran_params->SD_size_X_SU + sphere_data->sphere_local_pos_X[mySphereID];
        int64_t sphere_pos_relative_Y =
            ((int64_t)ownerSD_triplet.y) * gran_params->SD_size_Y_SU + sphere_data->sphere_local_pos_Y[mySphereID];
        int64_t sphere_pos_relative_Z =
            ((int64_t)ownerSD_triplet.z) * gran_params->SD_size_Z_SU + sphere_data->sphere_local_pos_Z[mySphereID];

        // printf("relative pos is %lld, %lld, %lld\n", sphere_pos_relative_X, sphere_pos_relative_Y,
        //        sphere_pos_relative_Z);
        figureOutTouchedSD(sphere_pos_relative_X, sphere_pos_relative_Y, sphere_pos_relative_Z, SDsTouched,
                           gran_params);
    }

    __syncthreads();

    // Sort by the ID of the SD touched
    BlockRadixSortOP(temp_storage_sort).Sort(SDsTouched, sphIDs);
    __syncthreads();

    // Do a winningStreak search on whole block, might not have high utilization here
    bool head_flags[MAX_SDs_TOUCHED_BY_SPHERE];
    Block_Discontinuity(temp_storage_disc).FlagHeads(head_flags, SDsTouched, cub::Inequality());
    __syncthreads();

    // Write back to shared memory; eight-way bank conflicts here - to revisit later
    for (unsigned int i = 0; i < MAX_SDs_TOUCHED_BY_SPHERE; i++) {
        shMem_head_flags[MAX_SDs_TOUCHED_BY_SPHERE * threadIdx.x + i] = head_flags[i];
    }

    // Seed offsetInComposite_SphInSD_Array with "no valid ID" so that we know later on what is legit;
    // No shmem bank coflicts here, good access...
    for (unsigned int i = 0; i < MAX_SDs_TOUCHED_BY_SPHERE; i++) {
        sphere_composite_offsets[i * CUB_THREADS + threadIdx.x] = NULL_CHGPU_ID;
    }

    __syncthreads();

    // Count how many times an SD shows up in conjunction with the collection of CUB_THREADS spheres. There
    // will be some thread divergence here.
    // Loop through each potential SD, after sorting, and see if it is the start of a head
    for (unsigned int i = 0; i < MAX_SDs_TOUCHED_BY_SPHERE; i++) {
        // SD currently touched, could easily be inlined
        unsigned int touchedSD = SDsTouched[i];
        if (touchedSD != NULL_CHGPU_ID && head_flags[i]) {
            // current index into shared datastructure of length 8*CUB_THREADS, could easily be inlined
            unsigned int idInShared = MAX_SDs_TOUCHED_BY_SPHERE * threadIdx.x + i;
            unsigned int winningStreak = 0;  // should always be under 256 by simulation constraints
            // This is the beginning of a sequence of SDs with a new ID
            do {
                winningStreak++;
                // Go until we run out of threads on the warp or until we find a new head
            } while (idInShared + winningStreak < MAX_SDs_TOUCHED_BY_SPHERE * CUB_THREADS &&
                     !(shMem_head_flags[idInShared + winningStreak]));

            // Store start of new entries
            // TODO this assumes that the offset is less than uint
            unsigned int sphere_offset = atomicAdd(sphere_data->SD_SphereCompositeOffsets + touchedSD, winningStreak);

            // Produce the offsets for this streak of spheres with identical SD ids
            for (unsigned int sphereInStreak = 0; sphereInStreak < winningStreak; sphereInStreak++) {
                // add this sphere to that sd, incrementing offset for next guy
                sphere_composite_offsets[idInShared + sphereInStreak] = sphere_offset++;
            }
        }
    }

    __syncthreads();  // needed since we write to shared memory above; i.e., offsetInComposite_SphInSD_Array

    // Write out the data now; register with sphere_data->spheres_in_SD_composite each sphere that touches a certain ID
    for (unsigned int i = 0; i < MAX_SDs_TOUCHED_BY_SPHERE; i++) {
        unsigned int offset = sphere_composite_offsets[MAX_SDs_TOUCHED_BY_SPHERE * threadIdx.x + i];
        // Add offsets together
        // bad SD means not a valid offset
        if (offset != NULL_CHGPU_ID) {
            // if (offset >= max_composite_index) {
            //     ABORTABORTABORT(
            //         "overrun during priming on thread %u block %u, offset is %zu, max is %zu,  sphere is %u\n",
            //         threadIdx.x, blockIdx.x, offset, max_composite_index, sphIDs[i]);
            // } else {
            // printf("%s\n", );
            sphere_data->spheres_in_SD_composite[offset] = sphIDs[i];
            // }
        }
    }
}

/// Get position offset between two SDs
// NOTE this assumes they are close together
inline __device__ int3 getOffsetFromSDs(unsigned int thisSD,
                                        unsigned int otherSD,
                                        ChSystemGpu_impl::GranParamsPtr gran_params) {
    int3 thisSDTrip = SDIDTriplet(thisSD, gran_params);
    int3 otherSDTrip = SDIDTriplet(otherSD, gran_params);
    int3 dist = {0, 0, 0};

    // points from this SD to the other SD
    dist.x = (otherSDTrip.x - thisSDTrip.x) * gran_params->SD_size_X_SU;
    dist.y = (otherSDTrip.y - thisSDTrip.y) * gran_params->SD_size_Y_SU;
    dist.z = (otherSDTrip.z - thisSDTrip.z) * gran_params->SD_size_Z_SU;

    return dist;
}

/// update local positions and SD based on global position
inline __device__ void findNewLocalCoords(ChSystemGpu_impl::GranSphereDataPtr sphere_data,
                                          unsigned int mySphereID,
                                          int64_t global_pos_X,
                                          int64_t global_pos_Y,
                                          int64_t global_pos_Z,
                                          ChSystemGpu_impl::GranParamsPtr gran_params) {
    int3 ownerSD = pointSDTriplet(global_pos_X, global_pos_Y, global_pos_Z, gran_params);

    // printf("sphere %u, ownerSD is %d, %d, %d\n", mySphereID, ownerSD.x, ownerSD.y, ownerSD.z);

    // now compute positions local to that SD
    // compute in 64 bit and cast to 32 bit
    // NOTE this assumes that we can store a local pos in 32 bits
    // local = global - SD = frame + global - frame_to_SD
    int sphere_pos_local_X =
        (int)(-gran_params->BD_frame_X + global_pos_X - (int64_t)ownerSD.x * gran_params->SD_size_X_SU);
    int sphere_pos_local_Y =
        (int)(-gran_params->BD_frame_Y + global_pos_Y - (int64_t)ownerSD.y * gran_params->SD_size_Y_SU);
    int sphere_pos_local_Z =
        (int)(-gran_params->BD_frame_Z + global_pos_Z - (int64_t)ownerSD.z * gran_params->SD_size_Z_SU);

    // printf("sphere %u, BD offsets are %lld, %lld, %lld\n", mySphereID, -gran_params->BD_frame_X,
    //        -gran_params->BD_frame_Y, -gran_params->BD_frame_Z);
    //
    // printf("sphere %u, SD offsets are %lld, %lld, %lld\n", mySphereID, -(int64_t)ownerSD.x *
    // gran_params->SD_size_X_SU,
    //        -(int64_t)ownerSD.y * gran_params->SD_size_Y_SU, -(int64_t)ownerSD.z * gran_params->SD_size_Z_SU);
    //
    // printf("sphere %u, global coords are %lld, %lld, %lld, local coords are %d, %d, %d in SD %u\n", mySphereID,
    //        global_pos_X, global_pos_Y, global_pos_Z, sphere_pos_local_X, sphere_pos_local_Y, sphere_pos_local_Z,
    //        SDTripletID(ownerSD, gran_params));

    unsigned int SDID = SDTripletID(ownerSD, gran_params);

    if (sphere_pos_local_X < 0 || sphere_pos_local_Y < 0 || sphere_pos_local_Z < 0) {
        float l_unit = gran_params->LENGTH_UNIT;
        printf(
            "error! sphere %u has negative local pos in SD %u (%d, %d, %d), pos_local: %e, %e, %e, pos_global: %e, %e, "
            "%e, BD starts at: %e, %e, %e\n",
            mySphereID, SDID, ownerSD.x, ownerSD.y, ownerSD.z, (float)sphere_pos_local_X * l_unit,
            (float)sphere_pos_local_Y * l_unit, (float)sphere_pos_local_Z * l_unit, (float)global_pos_X * l_unit,
            (float)global_pos_Y * l_unit, (float)global_pos_Z * l_unit, (float)gran_params->BD_frame_X * l_unit,
            (float)gran_params->BD_frame_Y * l_unit, (float)gran_params->BD_frame_Z * l_unit);
        __threadfence();
        cub::ThreadTrap();
    }

    // write local pos back to global memory
    sphere_data->sphere_local_pos_X[mySphereID] = sphere_pos_local_X;
    sphere_data->sphere_local_pos_Y[mySphereID] = sphere_pos_local_Y;
    sphere_data->sphere_local_pos_Z[mySphereID] = sphere_pos_local_Z;

    if (SDID >= gran_params->nSDs) {
        unsigned int mySphereID = threadIdx.x + blockIdx.x * blockDim.x;

        ABORTABORTABORT("ERROR! Sphere %u has invalid SD %u, max is %u, triplet %d, %d, %d\n", mySphereID, SDID,
                        gran_params->nSDs, ownerSD.x, ownerSD.y, ownerSD.z);
    }

    // write back which SD currently owns this sphere
    sphere_data->sphere_owner_SDs[mySphereID] = SDID;
}

/// when our BD frame moves, we need to change all local positions to account
static __global__ void applyBDFrameChange(int64_t3 delta,
                                          ChSystemGpu_impl::GranSphereDataPtr sphere_data,
                                          unsigned int nSpheres,
                                          ChSystemGpu_impl::GranParamsPtr gran_params) {
    unsigned int mySphereID = threadIdx.x + blockIdx.x * blockDim.x;

    if (mySphereID < nSpheres) {
        int3 sphere_pos_local =
            make_int3(sphere_data->sphere_local_pos_X[mySphereID], sphere_data->sphere_local_pos_Y[mySphereID],
                      sphere_data->sphere_local_pos_Z[mySphereID]);

        unsigned int ownerSD = sphere_data->sphere_owner_SDs[mySphereID];

        // find global pos in old frame, but add the offset
        int64_t3 sphPos_global = convertPosLocalToGlobal(ownerSD, sphere_pos_local, gran_params) + delta;

        findNewLocalCoords(sphere_data, mySphereID, sphPos_global.x, sphPos_global.y, sphPos_global.z, gran_params);
    }
}

/// Convert sphere positions from 64-bit global to 32-bit local
// only need to run once at beginning
static __global__ void initializeLocalPositions(ChSystemGpu_impl::GranSphereDataPtr sphere_data,
                                                int64_t* sphere_pos_global_X,
                                                int64_t* sphere_pos_global_Y,
                                                int64_t* sphere_pos_global_Z,
                                                unsigned int nSpheres,
                                                ChSystemGpu_impl::GranParamsPtr gran_params) {
    unsigned int mySphereID = threadIdx.x + blockIdx.x * blockDim.x;

    if (mySphereID < nSpheres) {
        int64_t global_pos_X = sphere_pos_global_X[mySphereID];
        int64_t global_pos_Y = sphere_pos_global_Y[mySphereID];
        int64_t global_pos_Z = sphere_pos_global_Z[mySphereID];
        findNewLocalCoords(sphere_data, mySphereID, global_pos_X, global_pos_Y, global_pos_Z, gran_params);
    }
}

/// Apply gravity to a sphere
inline __device__ void applyGravity(float3& sphere_force, ChSystemGpu_impl::GranParamsPtr gran_params) {
    sphere_force.x += gran_params->gravAcc_X_SU * gran_params->sphere_mass_SU;
    sphere_force.y += gran_params->gravAcc_Y_SU * gran_params->sphere_mass_SU;
    sphere_force.z += gran_params->gravAcc_Z_SU * gran_params->sphere_mass_SU;
}

/// Compute forces on a sphere from walls, BCs, and gravity
inline __device__ void applyExternalForces_frictionless(unsigned int ownerSD,
                                                        const int3& sphPos_local,  // local X position of DE
                                                        const float3& sphVel,      // Global X velocity of DE
                                                        float3& sphere_force,
                                                        ChSystemGpu_impl::GranParamsPtr gran_params,
                                                        ChSystemGpu_impl::GranSphereDataPtr sphere_data,
                                                        BC_type* bc_type_list,
                                                        BC_params_t<int64_t, int64_t3>* bc_params_list,
                                                        unsigned int nBCs) {
    int64_t3 sphPos_global = convertPosLocalToGlobal(ownerSD, sphPos_local, gran_params);

    // add forces from each BC
    for (unsigned int BC_id = 0; BC_id < nBCs; BC_id++) {
        // skip inactive BCs
        if (!bc_params_list[BC_id].active) {
            continue;
        }
        // TODO update for local coords
        switch (bc_type_list[BC_id]) {
                // these may use the frictionless overloads
            case BC_type::SPHERE: {
                addBCForces_Sphere_frictionless(sphPos_global, sphVel, sphere_force, gran_params, bc_params_list[BC_id],
                                                bc_params_list[BC_id].track_forces);
                break;
            }
            case BC_type::CONE: {
                addBCForces_ZCone_frictionless(sphPos_global, sphVel, sphere_force, gran_params, bc_params_list[BC_id],
                                               bc_params_list[BC_id].track_forces);
                break;
            }
            case BC_type::PLANE: {
                addBCForces_Plane_frictionless(sphPos_global, sphVel, sphere_force, gran_params, bc_params_list[BC_id],
                                               bc_params_list[BC_id].track_forces);
                break;
            }
            case BC_type::CYLINDER: {
                addBCForces_Zcyl_frictionless(sphPos_global, sphVel, sphere_force, gran_params, bc_params_list[BC_id],
                                              bc_params_list[BC_id].track_forces);
                break;
            }
        }
    }
    applyGravity(sphere_force, gran_params);
}

/// Compute forces on a sphere from walls, BCs, and gravity
inline __device__ void applyExternalForces(unsigned int currSphereID,
                                           unsigned int ownerSD,
                                           const int3& sphPos_local,  // Global X position of DE
                                           const float3& sphVel,      // Global X velocity of DE
                                           const float3& sphOmega,
                                           float3& sphere_force,
                                           float3& sphere_ang_acc,
                                           ChSystemGpu_impl::GranParamsPtr gran_params,
                                           ChSystemGpu_impl::GranSphereDataPtr sphere_data,
                                           BC_type* bc_type_list,
                                           BC_params_t<int64_t, int64_t3>* bc_params_list,
                                           unsigned int nBCs) {
    int64_t3 sphPos_global = convertPosLocalToGlobal(ownerSD, sphPos_local, gran_params);

    // add forces from each BC
    for (unsigned int BC_id = 0; BC_id < nBCs; BC_id++) {
        // skip inactive BCs
        if (!bc_params_list[BC_id].active) {
            continue;
        }
        switch (bc_type_list[BC_id]) {
            // case BC_type::AA_BOX: {
            //     ABORTABORTABORT("ERROR: AA_BOX is currently unsupported!\n");
            //     break;
            // }
            case BC_type::SPHERE: {
                addBCForces_Sphere_frictionless(sphPos_global, sphVel, sphere_force, gran_params, bc_params_list[BC_id],
                                                bc_params_list[BC_id].track_forces);
                break;
            }
            case BC_type::CONE: {
                addBCForces_ZCone_frictionless(sphPos_global, sphVel, sphere_force, gran_params, bc_params_list[BC_id],
                                               bc_params_list[BC_id].track_forces);
                break;
            }
            case BC_type::PLANE: {
                addBCForces_Plane(currSphereID, BC_id, sphPos_global, sphVel, sphOmega, sphere_force, sphere_ang_acc,
                                  gran_params, sphere_data, bc_params_list[BC_id], bc_params_list[BC_id].track_forces);
                break;
            }
            case BC_type::CYLINDER: {
                addBCForces_Zcyl(currSphereID, BC_id, sphPos_global, sphVel, sphOmega, sphere_force, sphere_ang_acc,
                                 gran_params, sphere_data, bc_params_list[BC_id], bc_params_list[BC_id].track_forces);

                break;
            }
        }
    }
    applyGravity(sphere_force, gran_params);
}

static __global__ void determineContactPairs(ChSystemGpu_impl::GranSphereDataPtr sphere_data,
                                             ChSystemGpu_impl::GranParamsPtr gran_params) {
    // Cache positions of spheres local to this SD
    __shared__ int3 sphere_pos_local[MAX_COUNT_OF_SPHERES_PER_SD];
    // the global ID of the spheres that touch this SD
    __shared__ unsigned int sphIDs[MAX_COUNT_OF_SPHERES_PER_SD];
    __shared__ not_stupid_bool sphFixed[MAX_COUNT_OF_SPHERES_PER_SD];

    unsigned int thisSD = blockIdx.x;
    unsigned int spheresTouchingThisSD = sphere_data->SD_NumSpheresTouching[thisSD];

    if (spheresTouchingThisSD == 0) {
        return;  // no spheres here, move along
    }

#ifdef DEBUG
    // If we overran, we have a major issue, time to crash before we make illegal memory accesses
    if (threadIdx.x == 0 && spheresTouchingThisSD > MAX_COUNT_OF_SPHERES_PER_SD) {
        // Crash now
        ABORTABORTABORT("TOO MANY SPHERES! SD %u has %u spheres\n", thisSD, spheresTouchingThisSD);
    }
#endif

    // Bring in data from global into shmem. Only a subset of threads get to do this.
    // Note that we're not using shared memory very heavily.
    if (threadIdx.x < spheresTouchingThisSD) {
        unsigned int offset_in_composite_Array = sphere_data->SD_SphereCompositeOffsets[thisSD] + threadIdx.x;
        unsigned int mySphereID = sphere_data->spheres_in_SD_composite[offset_in_composite_Array];

        unsigned int sphere_owner_SD = sphere_data->sphere_owner_SDs[mySphereID];
        sphere_pos_local[threadIdx.x] =
            make_int3(sphere_data->sphere_local_pos_X[mySphereID], sphere_data->sphere_local_pos_Y[mySphereID],
                      sphere_data->sphere_local_pos_Z[mySphereID]);
        // if this SD doesn't own that sphere, add an offset to account
        if (sphere_owner_SD != thisSD) {
            sphere_pos_local[threadIdx.x] =
                sphere_pos_local[threadIdx.x] + getOffsetFromSDs(thisSD, sphere_owner_SD, gran_params);
        }
        sphIDs[threadIdx.x] = mySphereID;
        sphFixed[threadIdx.x] = sphere_data->sphere_fixed[mySphereID];
    }

    __syncthreads();  // Needed to make sure data gets in shmem before using it elsewhere

    // Assumes each thread is a body, not the greatest assumption but we can fix that later
    // Note that if we have more threads than bodies, some effort gets wasted.
    unsigned int bodyA = threadIdx.x;

    // Body A in this SD looks at each other body B in the SD and determines whether that body B is touching body A
    if (bodyA < spheresTouchingThisSD) {
        unsigned int bodyA_sphereID = sphIDs[bodyA];
        unsigned int startingOffset = MAX_SPHERES_TOUCHED_BY_SPHERE * bodyA_sphereID;
        unsigned int ncontacts;
        for (unsigned char bodyB = 0; bodyB < spheresTouchingThisSD; bodyB++) {
            if (bodyA == bodyB || (sphFixed[bodyA] && sphFixed[bodyB])) {
                continue;
            }

            bool active_contact =
                checkContactExistsAndInThisSD(sphere_pos_local[bodyA], sphere_pos_local[bodyB], thisSD, gran_params);

            // nothing to do if contact is not present... Move on to next body in the SD
            if (!active_contact)
                continue;

            unsigned int bodyB_sphereID = sphIDs[bodyB];
            // Note that "ncontacts" contains the *OLD* # of contacts, before adding this one associated w/ body B.
            // Also, note that it's a waste to store "ncontacts" as an unsigned int, but atomicAdd doesn't work with
            // uint8_t, which is a type that would suffice.
            // Note that what gets atomicADD-incremented is the collection of contacts associated with body A
            ncontacts = atomicAdd(sphere_data->nCollisionsForEachBody + bodyA_sphereID, 1);  // reserving a spot...
            sphere_data->contact_partners_map[startingOffset + ncontacts] = bodyB_sphereID;
#ifdef DEBUG
            // to understand why "MAX_SPHERES_TOUCHED_BY_SPHERE-1", think what the atomicAdd returns
            if (ncontacts >= MAX_SPHERES_TOUCHED_BY_SPHERE - 1) {
                ABORTABORTABORT("Sphere %u touching more than 12 spheres.\n", bodyA_sphereID);
            }
#endif
            // make sure the contact history is now placed in the right location; for this, we need information from the
            // previous time step.
            unsigned int* previous_partners_map;
            float3* currentHistoryMap;
            float3* previousHistoryMap;
            if (sphere_data->contact_partners_map == sphere_data->contact_partners_mapEVEN) {
                // we're in even mode
                currentHistoryMap = sphere_data->contact_history_mapEVEN;
                previousHistoryMap = sphere_data->contact_history_mapODD;
                previous_partners_map = sphere_data->contact_partners_mapODD;
            } else {
                // we're in odd mode
                currentHistoryMap = sphere_data->contact_history_mapODD;
                previousHistoryMap = sphere_data->contact_history_mapEVEN;
                previous_partners_map = sphere_data->contact_partners_mapEVEN;
            }

            for (unsigned int offset = 0; offset < MAX_SPHERES_TOUCHED_BY_SPHERE; offset++) {
                unsigned int potentialSphere = previous_partners_map[startingOffset + offset];
                if (potentialSphere == bodyB_sphereID) {
                    // we have a "hit"; body_B was in contact with body_A at the previous time step
                    currentHistoryMap[startingOffset + ncontacts] = previousHistoryMap[startingOffset + offset];
                    break;
                } else if (potentialSphere == NULL_CHGPU_ID) {
                    // we exhausted the list of contacts at the previous time step for body_A; we didn't find body_B in
                    // this list, which means that (body_A,body_B) is a new contact pair that has just been established.
                    // As such, the micro-displacement is zero.
                    currentHistoryMap[startingOffset + ncontacts] = make_float3(0.f, 0.f, 0.f);
                    break;
                }
            }  // end looking in the previous list of contacts
        }      // done checking the bodies in this SD
    }
}

/// <summary>
/// At the end of each integration step, when multi-step friction is used, the micro-displacement history needs to be
/// curated. The older history is deleted, and the latest micro-displacements are labelled as "old". The same sort of
/// trick is done for the collection of contact pairs.
/// </summary>
/// <param name="nSpheres">number of spheres in the sim</param> 
/// <param name="nCollisionsForEachBody"> array with the number of contacts each body enages in</param>
/// <param name="contact_partners_map">array that contains for body A all the bodies body A comes in contact with</param>
/// <param name="contact_history_map">array of micro-displacements used to compute the friction force</param>
/// <returns></returns>
static __global__ void curateFrictionHistoryAposteriori(unsigned int nSpheres,
                                                        unsigned int* nCollisionsForEachBody,
                                                        unsigned int* contact_partners_map,
                                                        float3* contact_history_map) {
    unsigned int offset = threadIdx.x + blockIdx.x * blockDim.x;

    // reset the number of active contacts for each body to zero
    if (offset < nSpheres)
        nCollisionsForEachBody[offset] = 0;

    // Clean up all the contact partners bodies; set each partner body index to illegal value.
    // Zero out the tangential micro-deformation at the point of contact
    unsigned int sizeContactPairsArray = MAX_SPHERES_TOUCHED_BY_SPHERE * nSpheres;
    if (offset < sizeContactPairsArray) {
        contact_partners_map[offset] = NULL_CHGPU_ID;
        contact_history_map[offset] = make_float3(0.f, 0.f, 0.f);
    }
}

/// <summary>
/// Kernel populates the data structures with the right data at the beginning of the simulation, when there is no info
/// about contact pairs and contact micro-displacements
/// </summary>
/// <param name="nSpheres">number of spheres in the sim</param>
/// <param name="sphere_data">datastructure that holds all the pointers to system data</param>
/// <returns></returns>
static __global__ void seedFrictionHistory(unsigned int nSpheres,
                                           unsigned int* nCollisionsForEachBody,
                                           unsigned int* contact_partners_mapEVEN,
                                           unsigned int* contact_partners_mapODD,
                                           float3* contact_history_mapEVEN,
                                           float3* contact_history_mapODD) {
    unsigned int offset = threadIdx.x + blockIdx.x * blockDim.x;

    // reset the number of active contacts for each body to zero
    if (offset < nSpheres)
        nCollisionsForEachBody[offset] = 0;

    // clean up all the contact partners bodies; set to illegal value
    // zero out the tangential micro-deformation at the point of contact
    unsigned int sizeContactPairsArray = MAX_SPHERES_TOUCHED_BY_SPHERE * nSpheres;
    if (offset < sizeContactPairsArray) {
        contact_partners_mapEVEN[offset] = NULL_CHGPU_ID;
        contact_partners_mapODD[offset] = NULL_CHGPU_ID;
        contact_history_mapEVEN[offset] = make_float3(0.f, 0.f, 0.f);
        contact_history_mapODD[offset] = make_float3(0.f, 0.f, 0.f);
    }
}
/// Compute normal forces for a contacting pair
// returns the normal force and sets the reciplength, tangent velocity, and delta_r
// delta_r is direction of normal force on me
inline __device__ float3 computeSphereNormalForces(float& reciplength,
                                                   float3& vrel_t,
                                                   float3& delta_r,
                                                   const int3& sphereA_pos,
                                                   const int3& sphereB_pos,
                                                   const float3& sphereA_vel,
                                                   const float3& sphereB_vel,
                                                   ChSystemGpu_impl::GranParamsPtr gran_params) {
    // grab radius from global
    unsigned int sphereRadius_SU = gran_params->sphereRadius_SU;

    // compute penetrations in double
    double3 delta_r_double = int3_to_double3(sphereA_pos - sphereB_pos) / (2. * sphereRadius_SU);
    // compute in double then convert to float
    reciplength = (float)rsqrt(Dot(delta_r_double, delta_r_double));
    delta_r = make_float3(delta_r_double.x, delta_r_double.y, delta_r_double.z);

    // Velocity difference, it's better to do a coalesced access here than a fragmented access inside
    float3 v_rel = sphereA_vel - sphereB_vel;

    // n = delta_r * reciplength
    float3 contact_normal = delta_r * reciplength;

    // Compute force updates for damping term
    // Project relative velocity to the normal
    // proj = Dot(delta_dot, n)
    float projection = Dot(v_rel, contact_normal);

    // delta_dot = proj * n
    float3 vrel_n = projection * contact_normal;
    vrel_t = v_rel - vrel_n;

    // Compute penetration term, this becomes the delta as we want it
    float penetration_over_R = 2. * (1. - 1. / reciplength);
    // multiplier caused by Hooke vs Hertz force model
    float hertz_force_factor = sqrt(penetration_over_R);

    // add spring term
    float3 force_accum =
        hertz_force_factor * gran_params->K_n_s2s_SU * sphereRadius_SU * penetration_over_R * contact_normal;

    // Add damping term
    const float m_eff = gran_params->sphere_mass_SU / 2.f;
    force_accum = force_accum - gran_params->Gamma_n_s2s_SU * vrel_n * m_eff * hertz_force_factor;
    return force_accum;
}

/// each thread is a sphere, computing the forces its contact partners exert on it
static __global__ void computeSphereContactForces(ChSystemGpu_impl::GranSphereDataPtr sphere_data,
                                                  ChSystemGpu_impl::GranParamsPtr gran_params,
                                                  BC_type* bc_type_list,
                                                  BC_params_t<int64_t, int64_t3>* bc_params_list,
                                                  unsigned int nBCs,
                                                  unsigned int nSpheres) {
    // grab the sphere radius
    unsigned int sphereRadius_SU = gran_params->sphereRadius_SU;

    // my sphere ID, we're using a 1D thread->sphere map
    unsigned int mySphereID = threadIdx.x + blockIdx.x * blockDim.x;

    //    float force_unit = gran_params->MASS_UNIT * gran_params->LENGTH_UNIT / (gran_params->TIME_UNIT *
    //    gran_params->TIME_UNIT);

    // don't overrun the array
    if (mySphereID < nSpheres) {
        // my offset in the contact map
        unsigned int myOwnerSD = sphere_data->sphere_owner_SDs[mySphereID];

        // Bring in data from global
        int3 my_sphere_pos =
            make_int3(sphere_data->sphere_local_pos_X[mySphereID], sphere_data->sphere_local_pos_Y[mySphereID],
                      sphere_data->sphere_local_pos_Z[mySphereID]);
        // prepare in case we have friction
        float3 my_omega = {0.f, 0.f, 0.f};

        if (gran_params->friction_mode != CHGPU_FRICTION_MODE::FRICTIONLESS) {
            my_omega = make_float3(sphere_data->sphere_Omega_X[mySphereID], sphere_data->sphere_Omega_Y[mySphereID],
                                   sphere_data->sphere_Omega_Z[mySphereID]);
        }

        float3 my_sphere_vel = make_float3(sphere_data->pos_X_dt[mySphereID], sphere_data->pos_Y_dt[mySphereID],
                                           sphere_data->pos_Z_dt[mySphereID]);

        // Now compute the force each contact partner exerts
        // Force applied to this sphere
        float3 bodyA_force = {0.f, 0.f, 0.f};
        float3 bodyA_AngAcc = {0.f, 0.f, 0.f};

        unsigned int body_A_offset = MAX_SPHERES_TOUCHED_BY_SPHERE * mySphereID;
        // for each sphere contacting me, compute the forces
        unsigned int nContactsInvolvingBodyA = sphere_data->nCollisionsForEachBody[mySphereID];
        for (unsigned int contact_id = 0; contact_id < nContactsInvolvingBodyA; contact_id++) {
            unsigned int theirSphereID = sphere_data->contact_partners_map[body_A_offset + contact_id];
#ifdef DEBUG
            if (theirSphereID >= nSpheres) {
                ABORTABORTABORT("Invalid other sphere id found for sphere %u at slot %u, other is %u\n", mySphereID,
                                contact_id, theirSphereID);
            }
#endif

            unsigned int theirOwnerSD = sphere_data->sphere_owner_SDs[theirSphereID];
            int3 their_pos = make_int3(sphere_data->sphere_local_pos_X[theirSphereID],
                                       sphere_data->sphere_local_pos_Y[theirSphereID],
                                       sphere_data->sphere_local_pos_Z[theirSphereID]);

            if (theirOwnerSD != myOwnerSD) {
                // if the spheres are in different subdomains, offset their positions accordingly
                their_pos = their_pos + getOffsetFromSDs(myOwnerSD, theirOwnerSD, gran_params);
            }

            float3 vrel_t;      // tangent relative velocity
            float reciplength;  // used to compute contact normal
            float3 delta_r;     // used for contact normal
            float3 their_vel = make_float3(sphere_data->pos_X_dt[theirSphereID], sphere_data->pos_Y_dt[theirSphereID],
                                           sphere_data->pos_Z_dt[theirSphereID]);
            float3 force_accum = computeSphereNormalForces(reciplength, vrel_t, delta_r, my_sphere_pos, their_pos,
                                                           my_sphere_vel, their_vel, gran_params);

            if (gran_params->recording_contactInfo == true) {
                sphere_data->normal_contact_force[body_A_offset + contact_id] = force_accum;
            }

            float hertz_force_factor = std::sqrt(2. * (1 - (1. / reciplength)));  // sqrt(delta_n / (2 R_eff)

            // add frictional terms, if needed
            if (gran_params->friction_mode != CHGPU_FRICTION_MODE::FRICTIONLESS) {
                float3 their_omega =
                    make_float3(sphere_data->sphere_Omega_X[theirSphereID], sphere_data->sphere_Omega_Y[theirSphereID],
                                sphere_data->sphere_Omega_Z[theirSphereID]);
                // delta_r * radius is dimensional vector to center of contact point
                // (omega_b cross r_b - omega_a cross r_a), where r_b  = -r_a = delta_r * radius
                // add tangential components if they exist, these are automatically tangential from the cross
                // product
                vrel_t = vrel_t + Cross((my_omega + their_omega), -1.f * delta_r * sphereRadius_SU);

                // compute alpha due to rolling resistance (zero if rolling mode is no resistance)
                float3 rolling_resist_ang_acc = computeRollingAngAcc(
                    sphere_data, gran_params, gran_params->rolling_coeff_s2s_SU, gran_params->spinning_coeff_s2s_SU,
                    force_accum, my_omega, their_omega, delta_r * sphereRadius_SU);
                bodyA_AngAcc = bodyA_AngAcc + rolling_resist_ang_acc;

                const float m_eff = gran_params->sphere_mass_SU / 2.f;

                float3 tangent_force = computeFrictionForces(
                    gran_params, sphere_data, body_A_offset + contact_id, gran_params->static_friction_coeff_s2s,
                    gran_params->K_t_s2s_SU, gran_params->Gamma_t_s2s_SU, hertz_force_factor, m_eff, force_accum,
                    vrel_t, delta_r * reciplength);

                if (gran_params->recording_contactInfo == true) {
                    // record friction force
                    sphere_data->tangential_friction_force[body_A_offset + contact_id] = tangent_force;
                    // record rolling resistance torque
                    float3 rolling_resistance_torque =
                        rolling_resist_ang_acc * gran_params->sphereInertia_by_r * gran_params->sphereRadius_SU;
                    if (gran_params->rolling_mode != CHGPU_ROLLING_MODE::NO_RESISTANCE) {
                        sphere_data->rolling_friction_torque[body_A_offset + contact_id] = rolling_resistance_torque;
                    }
                }

                // tau = r cross f = radius * n cross F
                // 2 * radius * n = -1 * delta_r * sphdiameter
                // assume abs(r) ~ radius, so n = delta_r
                // compute accelerations caused by torques on body
                bodyA_AngAcc = bodyA_AngAcc + Cross(-1 * delta_r, tangent_force) / gran_params->sphereInertia_by_r;
                // add to total forces
                force_accum = force_accum + tangent_force;
            }

            // Add cohesion term against contact normal
            // delta_r * reciplength is contact normal
            force_accum =
                force_accum - gran_params->sphere_mass_SU * gran_params->cohesionAcc_s2s * delta_r * reciplength;

            // finally, we add this per-contact accumulator to the total force
            bodyA_force = bodyA_force + force_accum;
        }

        // add in gravity and wall forces
        applyExternalForces(mySphereID, myOwnerSD, my_sphere_pos, my_sphere_vel, my_omega, bodyA_force, bodyA_AngAcc,
                            gran_params, sphere_data, bc_type_list, bc_params_list, nBCs);

        // Write the force back to global memory so that we can apply them AFTER this kernel finishes
        atomicAdd(sphere_data->sphere_acc_X + mySphereID, bodyA_force.x / gran_params->sphere_mass_SU);
        atomicAdd(sphere_data->sphere_acc_Y + mySphereID, bodyA_force.y / gran_params->sphere_mass_SU);
        atomicAdd(sphere_data->sphere_acc_Z + mySphereID, bodyA_force.z / gran_params->sphere_mass_SU);

        if (gran_params->friction_mode == CHGPU_FRICTION_MODE::SINGLE_STEP ||
            gran_params->friction_mode == CHGPU_FRICTION_MODE::MULTI_STEP) {
            atomicAdd(sphere_data->sphere_ang_acc_X + mySphereID, bodyA_AngAcc.x);
            atomicAdd(sphere_data->sphere_ang_acc_Y + mySphereID, bodyA_AngAcc.y);
            atomicAdd(sphere_data->sphere_ang_acc_Z + mySphereID, bodyA_AngAcc.z);
        }
    }
}

static __global__ void computeSphereForces_frictionless(ChSystemGpu_impl::GranSphereDataPtr sphere_data,
                                                        ChSystemGpu_impl::GranParamsPtr gran_params,
                                                        BC_type* bc_type_list,
                                                        BC_params_t<int64_t, int64_t3>* bc_params_list,
                                                        unsigned int nBCs) {
    __shared__ int3 sphere_pos[MAX_COUNT_OF_SPHERES_PER_SD];  ///< store positions relative to *THIS* SD
    __shared__ float3 sphere_vel[MAX_COUNT_OF_SPHERES_PER_SD];
    __shared__ not_stupid_bool sphere_fixed[MAX_COUNT_OF_SPHERES_PER_SD];
    __shared__ unsigned int absoluteSphereID[MAX_COUNT_OF_SPHERES_PER_SD];

    unsigned int thisSD = blockIdx.x;
    unsigned int spheresTouchingThisSD = sphere_data->SD_NumSpheresTouching[thisSD];
    unsigned int mySphereID;
    unsigned int ncontacts = 0;

    if (spheresTouchingThisSD == 0) {
        return;  // no spheres here, move along
    }

    // Assumes each thread is a body; there will be some wasted threads if number of bodies in this SD is significantly
    // smaller than number of threads in the block.
    unsigned int bodyA = threadIdx.x;

    // If we overran, we have a major issue
#ifdef DEBUG
    if (bodyA == 0 && spheresTouchingThisSD > MAX_COUNT_OF_SPHERES_PER_SD) {
        ABORTABORTABORT("TOO MANY SPHERES! SD %u has %u spheres\n", thisSD, spheresTouchingThisSD);
    }
#endif

    // Bring in data from global into shmem. Only a subset of threads get to do this.
    // Note that we're not using shared memory very heavily.
    if (bodyA < spheresTouchingThisSD) {
        unsigned int offset_in_composite_Array = sphere_data->SD_SphereCompositeOffsets[thisSD] + bodyA;
        mySphereID = sphere_data->spheres_in_SD_composite[offset_in_composite_Array];
        absoluteSphereID[bodyA] = mySphereID;
        sphere_pos[bodyA] =
            make_int3(sphere_data->sphere_local_pos_X[mySphereID], sphere_data->sphere_local_pos_Y[mySphereID],
                      sphere_data->sphere_local_pos_Z[mySphereID]);

        unsigned int sphere_owner_SD = sphere_data->sphere_owner_SDs[mySphereID];
        // if this SD doesn't own that sphere, add an offset to account
        if (sphere_owner_SD != thisSD) {
            sphere_pos[bodyA] = sphere_pos[bodyA] + getOffsetFromSDs(thisSD, sphere_owner_SD, gran_params);
        }

        sphere_vel[bodyA] = make_float3(sphere_data->pos_X_dt[mySphereID], sphere_data->pos_Y_dt[mySphereID],
                                        sphere_data->pos_Z_dt[mySphereID]);
        sphere_fixed[bodyA] = sphere_data->sphere_fixed[mySphereID];
    }

    __syncthreads();  // Needed to make sure data gets in shmem before using it elsewhere

    // Each body looks at each other body and computes the force that the other body exerts on it
    // Force generated on this sphere

    if (bodyA < spheresTouchingThisSD) {
        float3 bodyA_force = {0.f, 0.f, 0.f};  // variable in which we accumulate all the forces acting of sphere A

        for (unsigned char bodyB = 0; bodyB < spheresTouchingThisSD; bodyB++) {
            if (bodyA == bodyB || (sphere_fixed[bodyA] && sphere_fixed[bodyB])) {
                continue;
            }

            bool active_contact =
                checkContactExistsAndInThisSD(sphere_pos[bodyA], sphere_pos[bodyB], thisSD, gran_params);

            // nothing to do if contact is not present... Move on to next body in the SD
            if (!active_contact)
                continue;

            // register this valid contact event with body A. It's ok to do it since A and B touch each other, and
            // the contact point is in this SD. This mem ops are quick, mostly involved shMem (with the exception of the
            // atomicAdd).
            // NOTE: in reality, this pairing is not needed for frictionless spheres to compute the normal force
            // (actually, see below how it's computed). However, this information is needed if one asks for the total
            // number of contacts in the system
            unsigned int sphereB_sysID = absoluteSphereID[bodyB];
            ncontacts = atomicAdd(sphere_data->nCollisionsForEachBody + mySphereID, 1);  // *OLD* # of contacts!!!
            sphere_data->contact_partners_map[ncontacts] = sphereB_sysID;
#ifdef DEBUG
            ncontacts++;
            if (ncontacts >= MAX_SPHERES_TOUCHED_BY_SPHERE) {
                ABORTABORTABORT("Sphere %u is touching 12 spheres already and we just found another!!!\n", mySphereID);
            }
#endif

            // Compute normal force...

            float3 vrel_t;      // unused but needed for function signature
            float reciplength;  // used to compute contact normal
            float3 delta_r;     // used for contact normal
            bodyA_force = bodyA_force + computeSphereNormalForces(reciplength, vrel_t, delta_r, sphere_pos[bodyA],
                                                                  sphere_pos[bodyB], sphere_vel[bodyA],
                                                                  sphere_vel[bodyB], gran_params);

            // Add cohesion term
            bodyA_force =
                bodyA_force - gran_params->sphere_mass_SU * gran_params->cohesionAcc_s2s * delta_r * reciplength;
        }

        // Apply external force.
        // IMPORTANT: Make sure that the sphere belongs to *this* SD, otherwise we'll end up with double
        // counting this force. If this SD owns the body, add its wall, BC, and grav forces
        unsigned int myOwnerSD = sphere_data->sphere_owner_SDs[mySphereID];
        if (myOwnerSD == thisSD) {
            applyExternalForces_frictionless(myOwnerSD, sphere_pos[bodyA], sphere_vel[bodyA], bodyA_force, gran_params,
                                             sphere_data, bc_type_list, bc_params_list, nBCs);
        }

        // Write the force back to global memory so that we can apply them AFTER this kernel finishes
        atomicAdd(sphere_data->sphere_acc_X + mySphereID, bodyA_force.x / gran_params->sphere_mass_SU);
        atomicAdd(sphere_data->sphere_acc_Y + mySphereID, bodyA_force.y / gran_params->sphere_mass_SU);
        atomicAdd(sphere_data->sphere_acc_Z + mySphereID, bodyA_force.z / gran_params->sphere_mass_SU);
    }
}

/// Compute update for a quantity using Forward Euler integrator
inline __device__ float integrateForwardEuler(float stepsize_SU, float val_dt) {
    return stepsize_SU * val_dt;
}

/// Compute update for a velocity using Chung integrator
inline __device__ float integrateChung_vel(float stepsize_SU, float acc, float acc_old) {
    constexpr float gamma_hat = -1.f / 2.f;
    constexpr float gamma = 3.f / 2.f;
    return stepsize_SU * (acc * gamma + acc_old * gamma_hat);
}

/// Compute update for a position using Chung integrator
inline __device__ float integrateChung_pos(float stepsize_SU, float vel_old, float acc, float acc_old) {
    constexpr float beta = 28.f / 27.f;
    constexpr float beta_hat = .5 - beta;
    return stepsize_SU * (vel_old + stepsize_SU * (acc * beta + acc_old * beta_hat));
}

/// Numerically integrates force to velocity and velocity to position
static __global__ void integrateSpheres(const float stepsize_SU,
                                        ChSystemGpu_impl::GranSphereDataPtr sphere_data,
                                        unsigned int nSpheres,
                                        ChSystemGpu_impl::GranParamsPtr gran_params) {
    // Figure out what sphereID this thread will handle. We work with a 1D block structure and a 1D grid
    // structure
    unsigned int mySphereID = threadIdx.x + blockIdx.x * blockDim.x;

    // Write back velocity updates
    if (mySphereID < nSpheres && !sphere_data->sphere_fixed[mySphereID]) {
        float curr_acc_X = sphere_data->sphere_acc_X[mySphereID];
        float curr_acc_Y = sphere_data->sphere_acc_Y[mySphereID];
        float curr_acc_Z = sphere_data->sphere_acc_Z[mySphereID];

        // Check to see if we messed up badly somewhere
        if (curr_acc_X == NAN || curr_acc_Y == NAN || curr_acc_Z == NAN) {
            ABORTABORTABORT("NAN force computed -- sphere is %u\n", mySphereID);
        }

        float old_vel_X = sphere_data->pos_X_dt[mySphereID];
        float old_vel_Y = sphere_data->pos_Y_dt[mySphereID];
        float old_vel_Z = sphere_data->pos_Z_dt[mySphereID];

        if (old_vel_X >= gran_params->max_safe_vel || old_vel_X == NAN || old_vel_Y >= gran_params->max_safe_vel ||
            old_vel_Y == NAN || old_vel_Z >= gran_params->max_safe_vel || old_vel_Z == NAN) {
            ABORTABORTABORT("Unsafe velocity computed -- sphere is %u, vel is (%f, %f, %f)\n", mySphereID, old_vel_X,
                            old_vel_Y, old_vel_Z);
        }

        float v_update_X = 0;
        float v_update_Y = 0;
        float v_update_Z = 0;

        // no divergence, same for every thread in block
        switch (gran_params->time_integrator) {
            case CHGPU_TIME_INTEGRATOR::CENTERED_DIFFERENCE:  // centered diff also computes velocity with the same
                                                              // signature as Euler
            case CHGPU_TIME_INTEGRATOR::EXTENDED_TAYLOR:      // fall through to Euler for this one
            case CHGPU_TIME_INTEGRATOR::FORWARD_EULER: {
                v_update_X = integrateForwardEuler(stepsize_SU, curr_acc_X);
                v_update_Y = integrateForwardEuler(stepsize_SU, curr_acc_Y);
                v_update_Z = integrateForwardEuler(stepsize_SU, curr_acc_Z);

                break;
            }
            case CHGPU_TIME_INTEGRATOR::CHUNG: {
                v_update_X = integrateChung_vel(stepsize_SU, curr_acc_X, sphere_data->sphere_acc_X_old[mySphereID]);
                v_update_Y = integrateChung_vel(stepsize_SU, curr_acc_Y, sphere_data->sphere_acc_Y_old[mySphereID]);
                v_update_Z = integrateChung_vel(stepsize_SU, curr_acc_Z, sphere_data->sphere_acc_Z_old[mySphereID]);

                break;
            }
        }

        // write back the velocity updates
        sphere_data->pos_X_dt[mySphereID] += v_update_X;
        sphere_data->pos_Y_dt[mySphereID] += v_update_Y;
        sphere_data->pos_Z_dt[mySphereID] += v_update_Z;

        // handle the positions
        float position_update_x = 0.f;
        float position_update_y = 0.f;
        float position_update_z = 0.f;
        // no divergence, same for every thread in block
        switch (gran_params->time_integrator) {
            case CHGPU_TIME_INTEGRATOR::EXTENDED_TAYLOR: {
                position_update_x = integrateForwardEuler(stepsize_SU, old_vel_X + 0.5 * curr_acc_X * stepsize_SU);
                position_update_y = integrateForwardEuler(stepsize_SU, old_vel_Y + 0.5 * curr_acc_Y * stepsize_SU);
                position_update_z = integrateForwardEuler(stepsize_SU, old_vel_Z + 0.5 * curr_acc_Z * stepsize_SU);
                break;
            }

            case CHGPU_TIME_INTEGRATOR::FORWARD_EULER: {
                position_update_x = integrateForwardEuler(stepsize_SU, old_vel_X);
                position_update_y = integrateForwardEuler(stepsize_SU, old_vel_Y);
                position_update_z = integrateForwardEuler(stepsize_SU, old_vel_Z);
                break;
            }
            case CHGPU_TIME_INTEGRATOR::CHUNG: {
                position_update_x =
                    integrateChung_pos(stepsize_SU, old_vel_X, curr_acc_X, sphere_data->sphere_acc_X_old[mySphereID]);
                position_update_y =
                    integrateChung_pos(stepsize_SU, old_vel_Y, curr_acc_Y, sphere_data->sphere_acc_Y_old[mySphereID]);
                position_update_z =
                    integrateChung_pos(stepsize_SU, old_vel_Z, curr_acc_Z, sphere_data->sphere_acc_Z_old[mySphereID]);
                break;
            }
            case CHGPU_TIME_INTEGRATOR::CENTERED_DIFFERENCE: {
                position_update_x = integrateForwardEuler(stepsize_SU, old_vel_X + v_update_X);
                position_update_y = integrateForwardEuler(stepsize_SU, old_vel_Y + v_update_Y);
                position_update_z = integrateForwardEuler(stepsize_SU, old_vel_Z + v_update_Z);
                break;
            }
        }
        int3 sphere_pos_local = make_int3(sphere_data->sphere_local_pos_X[mySphereID] + (lround)(position_update_x),
                                          sphere_data->sphere_local_pos_Y[mySphereID] + (lround)(position_update_y),
                                          sphere_data->sphere_local_pos_Z[mySphereID] + (lround)(position_update_z));

        int64_t3 sphPos_global =
            convertPosLocalToGlobal(sphere_data->sphere_owner_SDs[mySphereID], sphere_pos_local, gran_params);

        findNewLocalCoords(sphere_data, mySphereID, sphPos_global.x, sphPos_global.y, sphPos_global.z, gran_params);
    }
}

/**
 * Integrate angular accelerations. Called only when friction is on
 */
static __global__ void updateAngVels(const float stepsize_SU,
                                     ChSystemGpu_impl::GranSphereDataPtr sphere_data,
                                     unsigned int nSpheres,
                                     ChSystemGpu_impl::GranParamsPtr gran_params) {
    // Figure which sphereID this thread handles. We work with a 1D block structure and a 1D grid structure
    unsigned int mySphereID = threadIdx.x + blockIdx.x * blockDim.x;

    if (mySphereID >= nSpheres)
        return;

    // Write back velocity updates
    float omega_update_X = 0.f;
    float omega_update_Y = 0.f;
    float omega_update_Z = 0.f;

    // no divergence, same for every thread in block
    if (gran_params->time_integrator != CHGPU_TIME_INTEGRATOR::CHUNG) {
        // EXTENDED_TAYLOR:      has the same signature as forward Euler vels
        // CENTERED_DIFFERENCE:  has the same signature as forward Euler vels
        // FORWARD_EULER:
        // tau = I alpha => alpha = tau / I; we already computed these alphas
        omega_update_X = integrateForwardEuler(stepsize_SU, sphere_data->sphere_ang_acc_X[mySphereID]);
        omega_update_Y = integrateForwardEuler(stepsize_SU, sphere_data->sphere_ang_acc_Y[mySphereID]);
        omega_update_Z = integrateForwardEuler(stepsize_SU, sphere_data->sphere_ang_acc_Z[mySphereID]);
    } else {
        omega_update_X = integrateChung_vel(stepsize_SU, sphere_data->sphere_ang_acc_X[mySphereID],
                                            sphere_data->sphere_ang_acc_X_old[mySphereID]);
        omega_update_Y = integrateChung_vel(stepsize_SU, sphere_data->sphere_ang_acc_Y[mySphereID],
                                            sphere_data->sphere_ang_acc_Y_old[mySphereID]);
        omega_update_Z = integrateChung_vel(stepsize_SU, sphere_data->sphere_ang_acc_Z[mySphereID],
                                            sphere_data->sphere_ang_acc_Z_old[mySphereID]);
    }

    sphere_data->sphere_Omega_X[mySphereID] += omega_update_X;
    sphere_data->sphere_Omega_Y[mySphereID] += omega_update_Y;
    sphere_data->sphere_Omega_Z[mySphereID] += omega_update_Z;
}
/// @} gpu_cuda
