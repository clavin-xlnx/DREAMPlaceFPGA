/**
 * @file   pin_utilization_map_cuda_kernel.cu
 * @author Zixuan Jiang, Jiaqi Gu, Yibo Lin (DREAMPlace)
 * @date   Dec 2019
 * @brief  Compute the RUDY/RISA map for routing demand. 
 *         A routing/pin utilization estimator based on the following two papers
 *         "Fast and Accurate Routing Demand Estimation for efficient Routability-driven Placement", by Peter Spindler, DATE'07
 *         "RISA: Accurate and Efficient Placement Routability Modeling", by Chih-liang Eric Cheng, ICCAD'94
 */

#include "utility/src/utils.cuh"

DREAMPLACE_BEGIN_NAMESPACE

// fill the demand map net by net
template <typename T>
__global__ void pinDemandMap(const T *node_x, const T *node_y,
                          const T *node_size_x, const T *node_size_y,
                          const T *half_node_size_stretch_x, const T *half_node_size_stretch_y,
                          const T *pin_weights,
                          T xl, T yl, T xh, T yh,
                          T bin_size_x, T bin_size_y,
                          int num_bins_x, int num_bins_y,
                          int num_nodes,
                          T *pin_utilization_map
                          )
{
    const int i = threadIdx.x + blockDim.x * blockIdx.x;

    if (i < num_nodes)
    {
        const T node_center_x = node_x[i] + node_size_x[i]/2; 
        const T node_center_y = node_y[i] + node_size_y[i]/2; 

        const T x_min = node_center_x - half_node_size_stretch_x[i];
        const T x_max = node_center_x + half_node_size_stretch_x[i];
        int bin_index_xl = int((x_min - xl) / bin_size_x);
        int bin_index_xh = int((x_max - xl) / bin_size_x) + 1;
        bin_index_xl = DREAMPLACE_STD_NAMESPACE::max(bin_index_xl, 0);
        bin_index_xh = DREAMPLACE_STD_NAMESPACE::min(bin_index_xh, num_bins_x);

        const T y_min = node_center_y - half_node_size_stretch_y[i];
        const T y_max = node_center_y + half_node_size_stretch_y[i];
        int bin_index_yl = int((y_min - yl) / bin_size_y);
        int bin_index_yh = int((y_max - yl) / bin_size_y) + 1;
        bin_index_yl = DREAMPLACE_STD_NAMESPACE::max(bin_index_yl, 0);
        bin_index_yh = DREAMPLACE_STD_NAMESPACE::min(bin_index_yh, num_bins_y);

        T density = pin_weights[i] / (half_node_size_stretch_x[i] * half_node_size_stretch_y[i] * 4);
        for (int x = bin_index_xl; x < bin_index_xh; ++x)
        {
            for (int y = bin_index_yl; y < bin_index_yh; ++y)
            {
                T bin_xl = xl + x * bin_size_x; 
                T bin_yl = yl + y * bin_size_y; 
                T bin_xh = bin_xl + bin_size_x; 
                T bin_yh = bin_yl + bin_size_y; 
                T overlap = DREAMPLACE_STD_NAMESPACE::max(DREAMPLACE_STD_NAMESPACE::min(x_max, bin_xh) - DREAMPLACE_STD_NAMESPACE::max(x_min, bin_xl), (T)0) *
                            DREAMPLACE_STD_NAMESPACE::max(DREAMPLACE_STD_NAMESPACE::min(y_max, bin_yh) - DREAMPLACE_STD_NAMESPACE::max(y_min, bin_yl), (T)0);
                int index = x * num_bins_y + y;
                atomicAdd(pin_utilization_map + index, overlap * density);
            }
        }
    }
}

// fill the demand map net by net
template <typename T>
int pinDemandMapCudaLauncher(const T *node_x, const T *node_y,
                          const T *node_size_x, const T *node_size_y,
                          const T *half_node_size_stretch_x, const T *half_node_size_stretch_y,
                          const T *pin_weights,
                          T xl, T yl, T xh, T yh,
                          T bin_size_x, T bin_size_y,
                          int num_bins_x, int num_bins_y,
                          int num_nodes,
                          T *pin_utilization_map
                          )
{
    int thread_count = 512;
    int block_count = ceilDiv(num_nodes, thread_count);
    pinDemandMap<<<block_count, thread_count>>>(
            node_x, node_y,
            node_size_x, node_size_y,
            half_node_size_stretch_x, half_node_size_stretch_y,
            pin_weights,
            xl, yl, xh, yh,
            bin_size_x, bin_size_y,
            num_bins_x, num_bins_y,
            num_nodes,
            pin_utilization_map
        );
    return 0;
}

#define REGISTER_KERNEL_LAUNCHER(T)                                                                       \
    template int pinDemandMapCudaLauncher<T>(const T *node_x, const T *node_y, \
            const T *node_size_x, const T *node_size_y, \
            const T *half_node_size_stretch_x, const T *half_node_size_stretch_y, \
            const T *pin_weights, \
            T xl, T yl, T xh, T yh, \
            T bin_size_x, T bin_size_y, \
            int num_bins_x, int num_bins_y, \
            int num_nodes, \
            T *pin_utilization_map \
            );

REGISTER_KERNEL_LAUNCHER(float);
REGISTER_KERNEL_LAUNCHER(double);

DREAMPLACE_END_NAMESPACE
