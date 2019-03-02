#include "icp.h"
#include <thrust/scan.h>
#include <thrust/transform_reduce.h>
#include <thrust/functional.h>

// for matrix multi
#include "cublas_v2.h"
#define IDX2C(i, j, ld) (((j)*(ld))+(i))

namespace cuda_icp {

#define gpuErrchk(ans) { gpuAssert((ans), __FILE__, __LINE__); }
inline void gpuAssert(cudaError_t code, const char *file, int line, bool abort=true)
{
   if (code != cudaSuccess)
   {
      fprintf(stderr,"GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
      if (abort) exit(code);
   }
}

template<typename T>
struct thrust__squre : public thrust::unary_function<T,T>
{
  __host__ __device__ T operator()(const T &x) const
  {
    return x * x;
  }
};

__global__ void transform_pcd(Vec3f* model_pcd_ptr, size_t model_pcd_size, Mat4x4f trans){
    size_t i = blockIdx.x*blockDim.x + threadIdx.x;
    if(i >= model_pcd_size) return;

    Vec3f& pcd = model_pcd_ptr[i];
    float new_x = trans[0][0]*pcd.x + trans[0][1]*pcd.y + trans[0][2]*pcd.z + trans[0][3];
    float new_y = trans[1][0]*pcd.x + trans[1][1]*pcd.y + trans[1][2]*pcd.z + trans[1][3];
    float new_z = trans[2][0]*pcd.x + trans[2][1]*pcd.y + trans[2][2]*pcd.z + trans[2][3];
    pcd.x = new_x;
    pcd.y = new_y;
    pcd.z = new_z;
}

template<class Scene>
__global__ void get_Ab(const Scene scene, Vec3f* model_pcd_ptr, size_t model_pcd_size,
                        float* A_buffer_ptr, float* b_buffer_ptr, uint8_t* valid_buffer_ptr){
    size_t i = blockIdx.x*blockDim.x + threadIdx.x;
    if(i >= model_pcd_size) return;

    const auto& src_pcd = model_pcd_ptr[i];

    Vec3f dst_pcd, dst_normal; bool valid;
    scene.query(src_pcd, dst_pcd, dst_normal, valid);

    if(valid){

        // dot
        b_buffer_ptr[i] = (dst_pcd - src_pcd).x * dst_normal.x +
                      (dst_pcd - src_pcd).y * dst_normal.y +
                      (dst_pcd - src_pcd).z * dst_normal.z;

        // cross
        A_buffer_ptr[i*6 + 0] = dst_normal.z*src_pcd.y - dst_normal.y*src_pcd.z;
        A_buffer_ptr[i*6 + 1] = dst_normal.x*src_pcd.z - dst_normal.z*src_pcd.x;
        A_buffer_ptr[i*6 + 2] = dst_normal.y*src_pcd.x - dst_normal.x*src_pcd.y;

        A_buffer_ptr[i*6 + 3] = dst_normal.x;
        A_buffer_ptr[i*6 + 4] = dst_normal.y;
        A_buffer_ptr[i*6 + 5] = dst_normal.z;

        valid_buffer_ptr[i] = 1;
    }
    // else: invalid is 0 in A & b, ATA ATb means adding 0,
    // so don't need to consider valid_buffer, just multi matrix
}

template<class Scene>
RegistrationResult ICP_Point2Plane_cuda(PointCloud_cuda &model_pcd, const Scene scene,
                                        const ICPConvergenceCriteria criteria)
{
    RegistrationResult result;
    RegistrationResult backup;

    // buffer can make pcd handling indenpendent
    // may waste memory, but make it easy to parallel
    thrust::device_vector<float> A_buffer(model_pcd.size()*6, 0);
    thrust::device_vector<float> b_buffer(model_pcd.size(), 0);
    thrust::device_vector<uint8_t> valid_buffer(model_pcd.size(), 0);

    thrust::device_vector<float> A_dev(36);
    thrust::device_vector<float> b_dev(6);

    // cast to pointer, ready to feed kernel
    Vec3f* model_pcd_ptr = thrust::raw_pointer_cast(model_pcd.data());
    float* A_buffer_ptr =  thrust::raw_pointer_cast(A_buffer.data());
    float* b_buffer_ptr =  thrust::raw_pointer_cast(b_buffer.data());
    uint8_t* valid_buffer_ptr =  thrust::raw_pointer_cast(valid_buffer.data());

    float* A_dev_ptr =  thrust::raw_pointer_cast(A_dev.data());
    float* b_dev_ptr =  thrust::raw_pointer_cast(b_dev.data());

    const size_t threadsPerBlock = 256;
    const size_t numBlocks = (model_pcd.size() + threadsPerBlock - 1)/threadsPerBlock;

    /// cublas ----------------------------------------->
    cublasStatus_t stat;  // CUBLAS functions status
    cublasHandle_t cublas_handle;  // CUBLAS context
    stat = cublasCreate(&cublas_handle);
    float alpha =1.0f;  // al =1
    float beta =1.0f;  // bet =1
    /// cublas <-----------------------------------------

    thrust::host_vector<float> A_host(36);
    thrust::host_vector<float> b_host(36);

    float* A_host_ptr = A_host.data();
    float* b_host_ptr = b_host.data();

    // use one extra turn
    for(int iter=0; iter<= criteria.max_iteration_; iter++){

        get_Ab<<<numBlocks, threadsPerBlock>>>(scene, model_pcd_ptr, model_pcd.size(),
                                               A_buffer_ptr, b_buffer_ptr, valid_buffer_ptr);
        cudaDeviceSynchronize();

        int count = thrust::reduce(valid_buffer.begin(), valid_buffer.end());
        float total_error = thrust::transform_reduce(b_buffer.begin(), b_buffer.end(),
                                                     thrust__squre<float>(), 0, thrust::plus<float>());
        total_error = std::sqrt(total_error);

        backup = result;

        result.fitness_ = float(count) / model_pcd.size();
        result.inlier_rmse_ = total_error / count;

        // last extra iter, just compute fitness & mse
        if(iter == criteria.max_iteration_) return result;

        if(std::abs(result.fitness_ - backup.fitness_) < criteria.relative_fitness_ &&
           std::abs(result.inlier_rmse_ - backup.inlier_rmse_) < criteria.relative_rmse_){
            return result;
        }

        // A = A_buffer.transpose()*A_buffer;
        stat = cublasSsyrk(cublas_handle, CUBLAS_FILL_MODE_LOWER, CUBLAS_OP_N,
                            6, model_pcd.size(), &alpha, A_buffer_ptr, 6, &beta, A_dev_ptr, 6);
        stat = cublasGetMatrix(6, 6, sizeof(float), A_dev_ptr , 6, A_host_ptr, 6);

        // b = A_buffer.transpose()*b_buffer;
        stat = cublasSgemv(cublas_handle, CUBLAS_OP_N, 6, model_pcd.size(), &alpha, A_buffer_ptr,
                          6, b_buffer_ptr, 1, &beta, b_dev_ptr, 1);
        stat = cublasGetVector(6, sizeof(float), b_dev_ptr, 1, b_host_ptr, 1);

        Mat4x4f extrinsic = eigen_slover_666(A_host_ptr, b_host_ptr);

        transform_pcd<<<numBlocks, threadsPerBlock>>>(model_pcd_ptr, model_pcd.size(), extrinsic);

        result.transformation_ = extrinsic * result.transformation_;
    }

    // never arrive here
    return result;
}


}
