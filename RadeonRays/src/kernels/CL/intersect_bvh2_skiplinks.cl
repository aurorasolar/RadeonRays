/**********************************************************************
Copyright (c) 2016 Advanced Micro Devices, Inc. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
********************************************************************/
/**
    \file intersect_bvh2_skiplinks.cl
    \author Dmitry Kozlov
    \version 1.0
    \brief Intersector implementation based on BVH with skip links.

    IntersectorSkipLinks implementation is based on the following paper:
    "Efficiency Issues for Ray Tracing" Brian Smits
    http://www.cse.chalmers.se/edu/year/2016/course/course/TDA361/EfficiencyIssuesForRayTracing.pdf

    Intersector is using binary BVH with a single bounding box per node. BVH layout guarantees
    that left child of an internal node lies right next to it in memory. Each BVH node has a 
    skip link to the node traversed next. The traversal pseude code is

        while(addr is valid)
        {
            node <- fetch next node at addr
            if (rays intersects with node bbox)
            {
                if (node is leaf)
                    intersect leaf
                else
                {
                    addr <- addr + 1 (follow left child)
                    continue
                }
            }

            addr <- skiplink at node (follow next)
        }

    Pros:
        -Simple and efficient kernel with low VGPR pressure.
        -Can traverse trees of arbitrary depth.
    Cons:
        -Travesal order is fixed, so poor algorithmic characteristics.
        -Does not benefit from BVH quality optimizations.
 */

/*************************************************************************
 INCLUDES
 **************************************************************************/
#include <../RadeonRays/src/kernels/CL/common.cl>
/*************************************************************************
EXTENSIONS
**************************************************************************/

/*************************************************************************
DEFINES
**************************************************************************/
#define PI 3.14159265358979323846f
#define STARTIDX(x)     (((int)(x.pmin.w)) >> 4)
#define NUMPRIMS(x)     (((int)(x.pmin.w)) & 0xF)
#define LEAFNODE(x)     (((x).pmin.w) != -1.f)
#define NEXT(x)     ((int)((x).pmax.w))



/*************************************************************************
 TYPE DEFINITIONS
 **************************************************************************/
typedef bbox bvh_node;

typedef struct
{
    // Vertex indices
    int idx[3];
    // Shape ID
    int shape_id;
    // Primitive ID
    int prim_id;
} Face;

__attribute__((reqd_work_group_size(64, 1, 1)))
KERNEL 
void intersect_main(
    // BVH nodes
    GLOBAL bvh_node const* restrict nodes,
    // Triangle vertices
    GLOBAL float3 const* restrict vertices,
    // Triangle indices
    GLOBAL Face const* restrict faces,
    // Rays 
    GLOBAL ray const* restrict rays,
    // Number of rays
    GLOBAL int const* restrict num_rays,
    // Hit data
    GLOBAL Intersection* hits
)
{
    int global_id = get_global_id(0);

    if (global_id < *num_rays)
    {
        // Fetch ray
        ray const r = rays[global_id];

        if (ray_is_active(&r))
        {
            // Precompute inverse direction and origin / dir for bbox testing
            float3 const invdir = safe_invdir(r);
            float3 const oxinvdir = -r.o.xyz * invdir;
            // Intersection parametric distance
            float t_max = r.o.w;

            // Current node address
            int addr = 0;
            // Current closest face index
            int isect_idx = INVALID_IDX;

            while (addr != INVALID_IDX)
            {
                // Fetch next node
                bvh_node node = nodes[addr];
                // Intersect against bbox
                float2 s = fast_intersect_bbox1(node, invdir, oxinvdir, t_max);

                if (s.x <= s.y)
                {
                    // Check if the node is a leaf
                    if (LEAFNODE(node))
                    {
                        int const face_idx = STARTIDX(node);
                        Face const face = faces[face_idx];
#ifdef RR_RAY_MASK
                        if (ray_get_mask(&r) != face.shape_id)
                        {
#endif // RR_RAY_MASK
                            float3 const v1 = vertices[face.idx[0]];
                            float3 const v2 = vertices[face.idx[1]];
                            float3 const v3 = vertices[face.idx[2]];

                            // Intersect triangle
                            float const f = fast_intersect_triangle(r, v1, v2, v3, t_max);
                            // If hit update closest hit distance and index
                            if (f < t_max)
                            {
                                t_max = f;
                                isect_idx = face_idx;
                            }
#ifdef RR_RAY_MASK
                        }
#endif // RR_RAY_MASK
                    }
                    else
                    {
                        // Move to next node otherwise.
                        // Left child is always at addr + 1
                        ++addr;
                        continue;
                    }
                }

                addr = NEXT(node);
            }

            // Check if we have found an intersection
            if (isect_idx != INVALID_IDX)
            {
                // Fetch the node & vertices
                Face const face = faces[isect_idx];
                float3 const v1 = vertices[face.idx[0]];
                float3 const v2 = vertices[face.idx[1]];
                float3 const v3 = vertices[face.idx[2]];
                // Calculate hit position
                float3 const p = r.o.xyz + r.d.xyz * t_max;
                // Calculte barycentric coordinates
                float2 const uv = triangle_calculate_barycentrics(p, v1, v2, v3);
                // Update hit information
                hits[global_id].shape_id = face.shape_id;
                hits[global_id].prim_id = face.prim_id;
                hits[global_id].uvwt = make_float4(uv.x, uv.y, 0.f, t_max);
            }
            else
            {
                // Miss here
                hits[global_id].shape_id = MISS_MARKER;
                hits[global_id].prim_id = MISS_MARKER;
            }
        }
    }
}

__attribute__((reqd_work_group_size(64, 1, 1)))
KERNEL 
void occluded_main(
    // BVH nodes
    GLOBAL bvh_node const* restrict nodes,
    // Triangle vertices
    GLOBAL float3 const* restrict vertices,
    // Triangle indices
    GLOBAL Face const* restrict faces,
    // Rays 
    GLOBAL ray const* restrict rays,
    // Number of rays
    GLOBAL int const* restrict num_rays,
    // Hit data
    GLOBAL int* hits
)
{
    int global_id = get_global_id(0);

    // Handle only working subset
    if (global_id < *num_rays)
    {
        // Fetch ray
        ray const r = rays[global_id];

        if (ray_is_active(&r))
        {
            bool have_intersection = false;

            // Precompute inverse direction and origin / dir for bbox testing
            float3 const invdir = safe_invdir(r);
            float3 const oxinvdir = -r.o.xyz * invdir;
            // Intersection parametric distance
            float t_max = r.o.w;

            // Current node address
            int addr = 0;

            while (addr != INVALID_IDX)
            {
                // Fetch next node
                bvh_node node = nodes[addr];
                // Intersect against bbox
                float2 s = fast_intersect_bbox1(node, invdir, oxinvdir, t_max);

                if (s.x <= s.y)
                {
                    // Check if the node is a leaf
                    if (LEAFNODE(node))
                    {
                        int const face_idx = STARTIDX(node);
                        Face const face = faces[face_idx];
#ifdef RR_RAY_MASK
                        if (ray_get_mask(&r) != face.shape_id)
                        {
#endif // RR_RAY_MASK
                            float3 const v1 = vertices[face.idx[0]];
                            float3 const v2 = vertices[face.idx[1]];
                            float3 const v3 = vertices[face.idx[2]];

                            // Intersect triangle
                            float const f = fast_intersect_triangle(r, v1, v2, v3, t_max);
                            // If hit store the result and bail out
                            if (f < t_max)
                            {
                                hits[global_id] = HIT_MARKER;
                                have_intersection = true;
                                break;
                            }
#ifdef RR_RAY_MASK
                        }
#endif // RR_RAY_MASK
                    }
                    else
                    {
                        // Move to next node otherwise.
                        // Left child is always at addr + 1
                        ++addr;
                        continue;
                    }
                }

                addr = NEXT(node);
            }

            if (have_intersection == false)
            {
                // Finished traversal, but no intersection found
                hits[global_id] = MISS_MARKER;
            }
        }
    }
}

#define USE_ATOMIC

#ifdef USE_ATOMIC
inline float atomicadd(volatile __global float* address, const float value) {
    float old = value;
    while ((old = atomic_xchg(address, atomic_xchg(address, 0.0f)+old)) != 0.0f);
    return old;
}
#endif

__attribute__((reqd_work_group_size(64, 1, 1)))
KERNEL
void occluded_main_2d_sum_linear(
// BVH nodes
GLOBAL bvh_node const* restrict nodes,
// Triangle vertices
GLOBAL float3 const* restrict vertices,
// Triangle indices
GLOBAL Face const* restrict faces,

// Rays
GLOBAL float4 const* restrict origins,
GLOBAL float4 const* restrict directions,
GLOBAL float4 const* restrict koefs,

GLOBAL int const* restrict offset_directions,
GLOBAL int const* restrict offset_koefs,

// Number of origins and directions
GLOBAL int const* restrict num_origins,
GLOBAL int const* restrict num_directions,
GLOBAL int const* restrict stride_directions,
// Hit data
GLOBAL float* hits
)
{
    int num_rays = (*num_origins) * (*num_directions);
    
    int global_id = get_global_id(0);

    int origin_id = global_id % (*num_origins);
    int direction_id = (int)(global_id / (*num_origins));
    int direction_stride = (int)(direction_id % (*stride_directions));
    int output_offset = direction_stride * (*num_origins);
    
    // Handle only working subset
    if (global_id < num_rays)
    {
        const int direction_offset = offset_directions[origin_id];
        const int koefs_offset = offset_koefs[origin_id];

        const float4 koef = koefs[direction_id + koefs_offset];

        // Create ray
        ray r;
        r.o = origins[origin_id];
        r.d = directions[direction_id + direction_offset];
        r.extra.x = -1;
        r.extra.y = 1;
        r.doBackfaceCulling = 0;
        r.padding = 1;
        
        {
            bool have_intersection = false;

            // Precompute inverse direction and origin / dir for bbox testing
            float3 const invdir = safe_invdir(r);
            float3 const oxinvdir = -r.o.xyz * invdir;
            // Intersection parametric distance
            float t_max = r.o.w;
            
            // Current node address
            int addr = 0;
            
            while (addr != INVALID_IDX)
            {
                // Fetch next node
                bvh_node node = nodes[addr];
                // Intersect against bbox
                float2 s = fast_intersect_bbox1(node, invdir, oxinvdir, t_max);
                
                if (s.x <= s.y)
                {
                    // Check if the node is a leaf
                    if (LEAFNODE(node))
                    {
                        int const face_idx = STARTIDX(node);
                        Face const face = faces[face_idx];
                        #ifdef RR_RAY_MASK
                        if (ray_get_mask(&r) != face.shape_id)
                        {
                            #endif // RR_RAY_MASK
                            float3 const v1 = vertices[face.idx[0]];
                            float3 const v2 = vertices[face.idx[1]];
                            float3 const v3 = vertices[face.idx[2]];
                            
                            // Intersect triangle
                            float const f = fast_intersect_triangle(r, v1, v2, v3, t_max);
                            // If hit store the result and bail out
                            if (f < t_max)
                            {
                                #ifdef USE_ATOMIC
                                if (fabs(koef.x)>1e-4) {
                                    atomicadd(&hits[(output_offset + origin_id)*2], koef.x);
                                }
                                if (fabs(koef.z)>1e-4) {
                                    atomicadd(&hits[(output_offset + origin_id)*2+1], koef.z);
                                }
                                #else
                                    hits[(output_offset + origin_id)*2] += koef.x;
                                    hits[(output_offset + origin_id)*2+1] += koef.z;
                                #endif

                                // Normally we would just return here but Apple M1 OpenCL compiler sometimes behaves
                                // as if the return is never executed.
                                have_intersection = true;
                                break;
                            }
                            #ifdef RR_RAY_MASK
                        }
                        #endif // RR_RAY_MASK
                    }
                    else
                    {
                        // Move to next node otherwise.
                        // Left child is always at addr + 1
                        ++addr;
                        continue;
                    }
                }
                
                addr = NEXT(node);
            }

            if (have_intersection == false)
            {
                // Finished traversal, but no intersection found
                #ifdef USE_ATOMIC
                if (fabs(koef.y)>1e-4) {
                    atomicadd(&hits[(output_offset + origin_id)*2], koef.y);
                }
                if (fabs(koef.w)>1e-4) {
                    atomicadd(&hits[(output_offset + origin_id)*2+1], koef.w);
                }
                #else
                    hits[(output_offset + origin_id)*2] += koef.y;
                    hits[(output_offset + origin_id)*2+1] += koef.w;
                #endif
            }
        }
    }
}

__attribute__((reqd_work_group_size(64, 1, 1)))
KERNEL
void occluded_main_2d_cell_string(
// BVH nodes
GLOBAL bvh_node const* restrict nodes,
// Triangle vertices
GLOBAL float3 const* restrict vertices,
// Triangle indices
GLOBAL Face const* restrict faces,

// Rays
GLOBAL float4 const* restrict origins,
GLOBAL float4 const* restrict directions,

// Number of origins and directions
GLOBAL int const* restrict num_origins,
GLOBAL int const* restrict num_directions,

// Cell-string to point mappings
GLOBAL int const* restrict cell_string_inds,
GLOBAL int const* restrict num_cell_strings,

// Hit data
GLOBAL float* hits
)
{
    int global_id = get_global_id(0);


    // Handle only working subset
    int num_ray_batches = (*num_cell_strings) * (*num_directions);
    if (global_id < num_ray_batches)
    {
        bool have_intersection = false;

        // Map global_id to cell_string_id
        const int cell_string_id = global_id % (*num_cell_strings);

        // Map global_id to direction_id
        const int direction_id = (int)(global_id / (*num_cell_strings));

        int cs_pt_start = cell_string_inds[cell_string_id*2];
        int cs_pt_end = cell_string_inds[cell_string_id*2+1];

        // Iterate over all points in cell-string
        for (int i = cs_pt_start; i < cs_pt_end && have_intersection == false; i++) {

            // Create ray
            ray r;
            r.o = origins[i];
            r.d = directions[direction_id];
            r.extra.x = -1;
            r.extra.y = 1;
            r.doBackfaceCulling = 0;
            r.padding = 1;

            {
                // Precompute inverse direction and origin / dir for bbox testing
                float3 const invdir = safe_invdir(r);
                float3 const oxinvdir = -r.o.xyz * invdir;

                // Intersection parametric distance
                float t_max = r.o.w;

                // Current node address
                int addr = 0;

                while (addr != INVALID_IDX)
                {
                    // Fetch next node
                    bvh_node node = nodes[addr];
                    // Intersect against bbox
                    float2 s = fast_intersect_bbox1(node, invdir, oxinvdir, t_max);

                    if (s.x <= s.y)
                    {
                        // Check if the node is a leaf
                        if (LEAFNODE(node))
                        {
                            int const face_idx = STARTIDX(node);
                            Face const face = faces[face_idx];
                            #ifdef RR_RAY_MASK
                            if (ray_get_mask(&r) != face.shape_id)
                            {
                                #endif // RR_RAY_MASK
                                float3 const v1 = vertices[face.idx[0]];
                                float3 const v2 = vertices[face.idx[1]];
                                float3 const v3 = vertices[face.idx[2]];

                                // Intersect triangle
                                float const f = fast_intersect_triangle(r, v1, v2, v3, t_max);
                                // If hit store the result and bail out
                                if (f < t_max)
                                {
                                    hits[cell_string_id + direction_id * (*num_cell_strings)] = 1.;
                                    have_intersection = true;
                                    break;
                                }
                                #ifdef RR_RAY_MASK
                            }
                            #endif // RR_RAY_MASK
                        }
                        else
                        {
                            // Move to next node otherwise.
                            // Left child is always at addr + 1
                            ++addr;
                            continue;
                        }
                    }
                    addr = NEXT(node);
                }
            }
        }

        if (have_intersection == false)
        {
            // Finished traversal for all points in cell-string, but no intersection found
            hits[cell_string_id + direction_id * (*num_cell_strings)] = 0.;
        }
    }
}
