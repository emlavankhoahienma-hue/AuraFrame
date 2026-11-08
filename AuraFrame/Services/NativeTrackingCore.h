#ifndef NATIVE_TRACKING_CORE_H
#define NATIVE_TRACKING_CORE_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    double timestamp;
    double qx, qy, qz, qw;
} NTCMotionSample;

typedef struct {
    float dx, dy;
    float confidence;
    int inliers;
    bool isReliable;
} NTCPatchFlowResult;

void ntc_imu_push_sample(double timestamp, double qx, double qy, double qz, double qw);
bool ntc_imu_interpolate_pose(double timestamp, double* qx, double* qy, double* qz, double* qw);
double ntc_imu_current_angular_speed(void);
double ntc_imu_angular_displacement_since(double timestamp);
void ntc_s2_1euro_slerp(double prevX, double prevY, double prevZ,
                        double targetX, double targetY, double targetZ,
                        double focalScale, double dt,
                        double* outX, double* outY, double* outZ);

#ifdef __cplusplus
}
#endif

#endif // NATIVE_TRACKING_CORE_H
