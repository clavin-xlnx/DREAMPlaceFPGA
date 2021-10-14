/**
 * @file   lut_compatibility_cuda_kernel.cu
 * @author Rachel Selina Rajarathnam (DREAMPlaceFPGA)
 * @date   Oct 2020
 * @brief  Compute the Clustering compatibility map for LUT based on elfPlace.
 */

#include "utility/src/utils.cuh"
#include "utility/src/limits.cuh"
// local dependency
#include "clustering_compatibility/src/functions.h"

DREAMPLACE_BEGIN_NAMESPACE

/// define gaussian_auc_function 
template <typename T>
inline __device__ DEFINE_GAUSSIAN_AUC_FUNCTION(T);
/// define smooth_ceil_function
template <typename T>
inline __device__ DEFINE_SMOOTH_CEIL_FUNCTION(T);
/// define flop_aggregate_demand_function
template <typename T>
inline __device__ DEFINE_FLOP_AGGREGATE_DEMAND_FUNCTION(T);

template <typename T>
__global__ void fillDemandMapFF(const T *pos_x,
                                const T *pos_y,
                                const int *indices,
                                const int *ctrlSets,
                                const T *node_size_x,
                                const T *node_size_y,
                                const int num_bins_x, const int num_bins_y,
                                const int num_bins_ck, const int num_bins_ce,
                                int num_nodes,
                                T stddev_x, T stddev_y,
                                T inv_stddev_x, T inv_stddev_y, 
                                int ext_bin, T inv_sqrt,
                                T *demMap)
{
    const int i = threadIdx.x + blockDim.x * blockIdx.x;
    int n_o_p = num_bins_y * num_bins_ck * num_bins_ce;
    int o_p = num_bins_ck * num_bins_ce;
    if (i < num_nodes)
    {
        const int idx = indices[i];
        T node_x = pos_x[idx] + 0.5 * node_size_x[idx];
        T node_y = pos_y[idx] + 0.5 * node_size_y[idx];
        //Ctrl set values
        int cksr = ctrlSets[i*3 + 1];
        int ce = ctrlSets[i*3 + 2];

        int binX = int(node_x * inv_stddev_x);
        int binY = int(node_y * inv_stddev_y);

        // compute the bin box that this net will affect
        int bin_index_xl = DREAMPLACE_STD_NAMESPACE::max(binX - ext_bin, 0);
        int bin_index_xh = DREAMPLACE_STD_NAMESPACE::min(binX + ext_bin + 1, num_bins_x);

        int bin_index_yl = DREAMPLACE_STD_NAMESPACE::max(binY - ext_bin, 0);
        int bin_index_yh = DREAMPLACE_STD_NAMESPACE::min(binY + ext_bin + 1, num_bins_y);

        T gaussianX = gaussian_auc_function(node_x, stddev_x, bin_index_xl*stddev_x, bin_index_xh* stddev_x, inv_sqrt); 
        T gaussianY = gaussian_auc_function(node_y, stddev_y, bin_index_yl*stddev_y, bin_index_yh* stddev_y, inv_sqrt); 

        T sf = 1.0 / (gaussianX * gaussianY);

        for (int x = bin_index_xl; x < bin_index_xh; ++x)
        {
            T dem_xmbin_index_xl = gaussian_auc_function(node_x, stddev_x, x*stddev_x, (x+1)*stddev_x, inv_sqrt);
            for (int y = bin_index_yl; y < bin_index_yh; ++y)
            {
                int idx = x * n_o_p + y * o_p + cksr * num_bins_ce + ce; 
                T dem_ymbin_index_yl = gaussian_auc_function(node_y, stddev_y, y*stddev_y, (y+1)*stddev_y, inv_sqrt);
                //T dem = sf * demandX[x - bin_index_xl] * demandY[y - bin_index_yl];
                T dem = sf * dem_xmbin_index_xl * dem_ymbin_index_yl;
                //demMap[idx] += dem;
                atomicAdd(demMap + idx, dem);
            }
        }
    }
}

// Given a Gaussian demand map, compute demand of each instance type based on local window demand distribution
template <typename T>
__global__ void computeInstanceAreaFF(const T *demMap,
                                      const int num_bins_x, const int num_bins_y,
                                      const int num_bins_ck, const int num_bins_ce,
                                      T stddev_x, T stddev_y,int ext_bin,
                                      T bin_area, T half_slice, T *areaMap)
{
    const int i = threadIdx.x + blockDim.x * blockIdx.x;
    int total_bins = num_bins_x*num_bins_y;
    int n_o_p = num_bins_y * num_bins_ck * num_bins_ce;
    int o_p = num_bins_ck * num_bins_ce;
    if (i < total_bins)
    {
        int binX = int(i/num_bins_y);
        int binY = int(i%num_bins_y);

        // compute the bin box
        int bin_index_xl = DREAMPLACE_STD_NAMESPACE::max(binX - ext_bin, 0);
        int bin_index_xh = DREAMPLACE_STD_NAMESPACE::min(binX + ext_bin + 1, num_bins_x);

        int bin_index_yl = DREAMPLACE_STD_NAMESPACE::max(binY - ext_bin, 0);
        int bin_index_yh = DREAMPLACE_STD_NAMESPACE::min(binY + ext_bin + 1, num_bins_y);

        int index = binX * n_o_p + binY * o_p;

        for (int x = bin_index_xl; x < bin_index_xh; ++x)
        {
            for (int y = bin_index_yl; y < bin_index_yh; ++y)
            {
                if (x != binX && y != binY)
                {
                    int idx = x * n_o_p + y * o_p;
                    flop_aggregate_demand_function(demMap, idx, areaMap, index, num_bins_ck, num_bins_ce);
                }
            }
        }

        //Flop compute areas
        for (int ck = 0; ck < num_bins_ck; ++ck)
        {
            T totalQ = 0.0;
            for (int ce = 0; ce < num_bins_ce; ++ce)
            {
                int updIdx = index + ck*num_bins_ce + ce;
                if (areaMap[updIdx] > 0.0)
                {
                    totalQ += smooth_ceil_function(areaMap[updIdx]* 0.25, 0.25);
                }
            }

            T sf = half_slice * smooth_ceil_function(totalQ*0.5, 0.5) / totalQ;

            for (int cE = 0; cE < num_bins_ce; ++cE)
            {
                int updIdx = index + ck*num_bins_ce + cE;
                if (areaMap[updIdx] > 0.0)
                {
                    T qrt = smooth_ceil_function(areaMap[updIdx]* 0.25, 0.25);
                    areaMap[updIdx] = sf * qrt / areaMap[updIdx];
                }
            }
        }
    }
}


// Set a set of instance area in a area vector based on the given area map
template <typename T>
__global__ void collectInstanceAreasFF(const T *pos_x,
                                       const T *pos_y,
                                       const int *indices,
                                       const int *ctrlSets,
                                       const T *node_size_x,
                                       const T *node_size_y,
                                       const int num_bins_y,
                                       const int num_bins_ck, const int num_bins_ce,
                                       const T *areaMap,
                                       int num_nodes,T inv_stddev_x,
                                       T inv_stddev_y,
                                       T *instAreas)
{
    const int i = threadIdx.x + blockDim.x * blockIdx.x;
    int n_o_p = num_bins_y * num_bins_ck * num_bins_ce;
    int o_p = num_bins_ck * num_bins_ce;
    if (i < num_nodes)
    {
        const int idx = indices[i];
        T node_x = pos_x[idx] + 0.5 * node_size_x[idx];
        T node_y = pos_y[idx] + 0.5 * node_size_y[idx];
        //Ctrl set values
        int cksr = ctrlSets[i*3 + 1];
        int ce = ctrlSets[i*3 + 2];

        int binX = int(node_x * inv_stddev_x);
        int binY = int(node_y * inv_stddev_y);

        int index = binX * n_o_p + binY * o_p + cksr * num_bins_ce + ce;
        instAreas[idx] = areaMap[index];
    }
}

// fill the demand map net by net
template <typename T>
int fillDemandMapFFCuda(const T *pos_x, const T *pos_y,
                        const int *indices, const int *ctrlSets,
                        const T *node_size_x, const T *node_size_y,
                        const int num_bins_x, const int num_bins_y,
                        const int num_bins_ck, const int num_bins_ce,
                        int num_nodes,
                        T stddev_x, T stddev_y,
                        T inv_stddev_x, T inv_stddev_y, 
                        int ext_bin, T inv_sqrt,
                        T *demMap)
{
    int thread_count = 512;
    int block_count = CPUCeilDiv(num_nodes, thread_count);
    fillDemandMapFF<<<block_count, thread_count>>>(
                                                    pos_x,
                                                    pos_y,
                                                    indices,
                                                    ctrlSets,
                                                    node_size_x,
                                                    node_size_y,
                                                    num_bins_x, num_bins_y,
                                                    num_bins_ck, num_bins_ce,
                                                    num_nodes, stddev_x, stddev_y,
                                                    inv_stddev_x, inv_stddev_y, 
                                                    ext_bin, inv_sqrt,
                                                    demMap
                                                    );
    return 0;
}

// Given a Gaussian demand map, compute demand of each instance type based on local window demand distribution
template <typename T>
int computeInstanceAreaFFCuda(const T *demMap,
                              const int num_bins_x, const int num_bins_y,
                              const int num_bins_ck, const int num_bins_ce,
                              T stddev_x, T stddev_y, int ext_bin,
                              T bin_area, T half_slice, T *areaMap)
{
    int thread_count = 512;
    int block_count = CPUCeilDiv(num_bins_x*num_bins_y, thread_count);
    computeInstanceAreaFF<<<block_count, thread_count>>>(
                                                          demMap,
                                                          num_bins_x, num_bins_y,
                                                          num_bins_ck, num_bins_ce,
                                                          stddev_x, stddev_y,
                                                          ext_bin, bin_area, 
                                                          half_slice, areaMap
                                                          );
    return 0;
}


// Set a set of instance area in a area vector based on the given area map
template <typename T>
int collectInstanceAreasFFCuda(const T *pos_x,
                               const T *pos_y,
                               const int *indices,
                               const int *ctrlSets,
                               const T *node_size_x,
                               const T *node_size_y,
                               const int num_bins_y,
                               const int num_bins_ck, const int num_bins_ce,
                               const T *areaMap,
                               int num_nodes,
                               T inv_stddev_x, T inv_stddev_y, 
                               T *instAreas)
{
    int thread_count = 512;
    int block_count = CPUCeilDiv(num_nodes, thread_count);
    collectInstanceAreasFF<<<block_count, thread_count>>>(
                                                           pos_x, pos_y,
                                                           indices, ctrlSets, 
                                                           node_size_x, node_size_y,
                                                           num_bins_y, num_bins_ck,
                                                           num_bins_ce,
                                                           areaMap, num_nodes,
                                                           inv_stddev_x, inv_stddev_y,
                                                           instAreas
                                                           );
    return 0;
}

#define REGISTER_KERNEL_LAUNCHER(T)                                                     \
    int instantiatefillDemandMapFFCuda(                                                 \
        const T *pos_x, const T *pos_y, const int *indices, const int *ctrlSets,        \
        const T *node_size_x, const T *node_size_y, const int num_bins_x,               \
        const int num_bins_y, const int num_bins_ck, const int num_bins_ce,             \
        int num_nodes, T stddev_x, T stddev_y, T inv_stddev_x, T inv_stddev_y,          \
        int ext_bin, T inv_sqrt, T *demMap) {                                           \
    return fillDemandMapFFCuda(                                                         \
        pos_x, pos_y, indices, ctrlSets, node_size_x, node_size_y, num_bins_x,          \
        num_bins_y, num_bins_ck, num_bins_ce, num_nodes, stddev_x, stddev_y,            \
        inv_stddev_x, inv_stddev_y, ext_bin, inv_sqrt, demMap);                         \
        }                                                                               \
                                                                                        \
    int instantiatecomputeInstanceAreaFFCuda(                                           \
        const T *demMap, const int num_bins_x, const int num_bins_y,                    \
        const int num_bins_ck, const int num_bins_ce, T stddev_x, T stddev_y,           \
        int ext_bin, T bin_area, T half_slice, T *areaMap) {                            \
    return computeInstanceAreaFFCuda(                                                   \
        demMap, num_bins_x, num_bins_y, num_bins_ck, num_bins_ce, stddev_x, stddev_y,   \
        ext_bin, bin_area, half_slice, areaMap);                                        \
        }                                                                               \
                                                                                        \
    int instantiatecollectInstanceAreasFFCuda(                                          \
        const T *pos_x, const T *pos_y, const int *indices, const int *ctrlSets,        \
        const T *node_size_x, const T *node_size_y, const int num_bins_y,               \
        const int num_bins_ck, const int num_bins_ce, const T *areaMap, int num_nodes,  \
        T inv_stddev_x, T inv_stddev_y, T *instAreas) {                                 \
    return collectInstanceAreasFFCuda(                                                  \
        pos_x, pos_y, indices, ctrlSets, node_size_x, node_size_y, num_bins_y,          \
        num_bins_ck, num_bins_ce, areaMap, num_nodes, inv_stddev_x, inv_stddev_y,       \
        instAreas);                                                                     \
        }                                                                               \

REGISTER_KERNEL_LAUNCHER(float);
REGISTER_KERNEL_LAUNCHER(double);

DREAMPLACE_END_NAMESPACE
