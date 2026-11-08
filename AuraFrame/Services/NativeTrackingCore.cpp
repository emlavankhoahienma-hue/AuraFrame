#include "NativeTrackingCore.h"

#include <cmath>
#include <vector>
#include <mutex>
#include <algorithm>
#include <numbers>

namespace {

struct Quaternion {
    double x{0.0};
    double y{0.0};
    double z{0.0};
    double w{1.0};

    [[nodiscard]] double norm() const {
        return std::sqrt(x * x + y * y + z * z + w * w);
    }

    void normalize() {
        const double n = norm();
        if (n > 1e-12) {
            const double inv = 1.0 / n;
            x *= inv;
            y *= inv;
            z *= inv;
            w *= inv;
        } else {
            x = 0.0;
            y = 0.0;
            z = 0.0;
            w = 1.0;
        }
    }

    [[nodiscard]] double dot(const Quaternion& other) const {
        return x * other.x + y * other.y + z * other.z + w * other.w;
    }

    static Quaternion slerp(Quaternion q0, Quaternion q1, double t) {
        q0.normalize();
        q1.normalize();

        double cosHalfTheta = q0.dot(q1);

        if (cosHalfTheta < 0.0) {
            q1.x = -q1.x;
            q1.y = -q1.y;
            q1.z = -q1.z;
            q1.w = -q1.w;
            cosHalfTheta = -cosHalfTheta;
        }

        if (cosHalfTheta > 0.9995) {
            Quaternion result{
                q0.x + t * (q1.x - q0.x),
                q0.y + t * (q1.y - q0.y),
                q0.z + t * (q1.z - q0.z),
                q0.w + t * (q1.w - q0.w)
            };
            result.normalize();
            return result;
        }

        cosHalfTheta = std::clamp(cosHalfTheta, -1.0, 1.0);
        const double halfTheta = std::acos(cosHalfTheta);
        const double sinHalfTheta = std::sqrt(std::max(0.0, 1.0 - cosHalfTheta * cosHalfTheta));

        if (sinHalfTheta < 1e-6) {
            return q0;
        }

        const double ratioA = std::sin((1.0 - t) * halfTheta) / sinHalfTheta;
        const double ratioB = std::sin(t * halfTheta) / sinHalfTheta;

        Quaternion result{
            ratioA * q0.x + ratioB * q1.x,
            ratioA * q0.y + ratioB * q1.y,
            ratioA * q0.z + ratioB * q1.z,
            ratioA * q0.w + ratioB * q1.w
        };
        result.normalize();
        return result;
    }
};

class IMURingBuffer {
public:
    static constexpr size_t kCapacity = 640;

    IMURingBuffer() : buffer_(kCapacity) {}

    void push(double timestamp, double qx, double qy, double qz, double qw) {
        Quaternion q{qx, qy, qz, qw};
        q.normalize();

        std::lock_guard<std::mutex> lock(mutex_);
        buffer_[head_] = NTCMotionSample{timestamp, q.x, q.y, q.z, q.w};
        head_ = (head_ + 1) % kCapacity;
        if (size_ < kCapacity) {
            ++size_;
        }
    }

    bool interpolate(double timestamp, double* qx, double* qy, double* qz, double* qw) {
        std::lock_guard<std::mutex> lock(mutex_);
        return interpolateInternal(timestamp, qx, qy, qz, qw);
    }

    double currentAngularSpeed() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (size_ < 2) {
            return 0.0;
        }

        const size_t curIdx = (head_ + kCapacity - 1) % kCapacity;
        const size_t prevIdx = (curIdx + kCapacity - 1) % kCapacity;

        const auto& sCur = buffer_[curIdx];
        const auto& sPrev = buffer_[prevIdx];

        const double dt = sCur.timestamp - sPrev.timestamp;
        if (dt <= 1e-6) {
            return 0.0;
        }

        const Quaternion qCur{sCur.qx, sCur.qy, sCur.qz, sCur.qw};
        const Quaternion qPrev{sPrev.qx, sPrev.qy, sPrev.qz, sPrev.qw};

        const double dot = std::clamp(std::abs(qCur.dot(qPrev)), -1.0, 1.0);
        const double angle = 2.0 * std::acos(dot);
        return angle / dt;
    }

    double angularDisplacementSince(double timestamp) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (size_ < 1) {
            return 0.0;
        }

        const size_t curIdx = (head_ + kCapacity - 1) % kCapacity;
        const auto& sCur = buffer_[curIdx];
        const Quaternion qCur{sCur.qx, sCur.qy, sCur.qz, sCur.qw};

        double qx = 0.0, qy = 0.0, qz = 0.0, qw = 1.0;
        if (!interpolateInternal(timestamp, &qx, &qy, &qz, &qw)) {
            return 0.0;
        }

        const Quaternion qPast{qx, qy, qz, qw};
        const double dot = std::clamp(std::abs(qCur.dot(qPast)), -1.0, 1.0);
        return 2.0 * std::acos(dot);
    }

private:
    bool interpolateInternal(double timestamp, double* qx, double* qy, double* qz, double* qw) const {
        if (size_ < 2) {
            return false;
        }

        const size_t newestIdx = (head_ + kCapacity - 1) % kCapacity;
        const size_t oldestIdx = (head_ + kCapacity - size_) % kCapacity;

        if (timestamp > buffer_[newestIdx].timestamp + 0.1 || timestamp < buffer_[oldestIdx].timestamp - 0.1) {
            return false;
        }

        if (timestamp >= buffer_[newestIdx].timestamp) {
            *qx = buffer_[newestIdx].qx;
            *qy = buffer_[newestIdx].qy;
            *qz = buffer_[newestIdx].qz;
            *qw = buffer_[newestIdx].qw;
            return true;
        }

        if (timestamp <= buffer_[oldestIdx].timestamp) {
            *qx = buffer_[oldestIdx].qx;
            *qy = buffer_[oldestIdx].qy;
            *qz = buffer_[oldestIdx].qz;
            *qw = buffer_[oldestIdx].qw;
            return true;
        }

        for (size_t i = 0; i < size_ - 1; ++i) {
            const size_t curIdx = (head_ + kCapacity - 1 - i) % kCapacity;
            const size_t prevIdx = (curIdx + kCapacity - 1) % kCapacity;

            const auto& sNew = buffer_[curIdx];
            const auto& sOld = buffer_[prevIdx];

            if (timestamp >= sOld.timestamp && timestamp <= sNew.timestamp) {
                const double span = sNew.timestamp - sOld.timestamp;
                const double t = (span > 1e-7) ? ((timestamp - sOld.timestamp) / span) : 0.0;

                const Quaternion qOld{sOld.qx, sOld.qy, sOld.qz, sOld.qw};
                const Quaternion qNew{sNew.qx, sNew.qy, sNew.qz, sNew.qw};
                const Quaternion interp = Quaternion::slerp(qOld, qNew, t);

                *qx = interp.x;
                *qy = interp.y;
                *qz = interp.z;
                *qw = interp.w;
                return true;
            }
        }

        return false;
    }

    std::vector<NTCMotionSample> buffer_;
    size_t head_{0};
    size_t size_{0};
    std::mutex mutex_;
};

IMURingBuffer g_imuBuffer;

} // namespace

extern "C" {

void ntc_imu_push_sample(double timestamp, double qx, double qy, double qz, double qw) {
    g_imuBuffer.push(timestamp, qx, qy, qz, qw);
}

bool ntc_imu_interpolate_pose(double timestamp, double* qx, double* qy, double* qz, double* qw) {
    if (!qx || !qy || !qz || !qw) {
        return false;
    }
    return g_imuBuffer.interpolate(timestamp, qx, qy, qz, qw);
}

double ntc_imu_current_angular_speed(void) {
    return g_imuBuffer.currentAngularSpeed();
}

double ntc_imu_angular_displacement_since(double timestamp) {
    return g_imuBuffer.angularDisplacementSince(timestamp);
}

void ntc_s2_1euro_slerp(double prevX, double prevY, double prevZ,
                        double targetX, double targetY, double targetZ,
                        double focalScale, double dt,
                        double* outX, double* outY, double* outZ) {
    if (!outX || !outY || !outZ) {
        return;
    }

    // 1. Normalize previous vector
    const double normP = std::sqrt(prevX * prevX + prevY * prevY + prevZ * prevZ);
    double px = (normP > 1e-9) ? (prevX / normP) : 0.0;
    double py = (normP > 1e-9) ? (prevY / normP) : 0.0;
    double pz = (normP > 1e-9) ? (prevZ / normP) : 1.0;

    // 2. Normalize target vector
    const double normT = std::sqrt(targetX * targetX + targetY * targetY + targetZ * targetZ);
    double tx = (normT > 1e-9) ? (targetX / normT) : 0.0;
    double ty = (normT > 1e-9) ? (targetY / normT) : 0.0;
    double tz = (normT > 1e-9) ? (targetZ / normT) : 1.0;

    // 3. Dot and Cross products
    const double dotVal = std::clamp(px * tx + py * ty + pz * tz, -1.0, 1.0);
    const double crossX = py * tz - pz * ty;
    const double crossY = pz * tx - px * tz;
    const double crossZ = px * ty - py * tx;
    const double crossNorm = std::sqrt(crossX * crossX + crossY * crossY + crossZ * crossZ);

    const double theta = std::atan2(crossNorm, dotVal);

    if (dt <= 1e-7 || theta < 1e-7) {
        *outX = tx;
        *outY = ty;
        *outZ = tz;
        return;
    }

    // 4. Velocity-adaptive cutoff frequency
    const double scaledTheta = theta * focalScale * 120.0;
    const double cutoffHz = 14.0 + std::min(85.0, scaledTheta);

    // 5. 1-Euro smoothing factor alpha
    const double tau = 1.0 / (2.0 * std::numbers::pi * cutoffHz);
    const double alpha = std::clamp(dt / (tau + dt), 0.0, 1.0);

    // 6. Geodesic SLERP on S^2 sphere
    const double sinTheta = std::sin(theta);
    double rx, ry, rz;

    if (sinTheta > 1e-6) {
        const double wP = std::sin((1.0 - alpha) * theta) / sinTheta;
        const double wT = std::sin(alpha * theta) / sinTheta;
        rx = wP * px + wT * tx;
        ry = wP * py + wT * ty;
        rz = wP * pz + wT * tz;
    } else {
        rx = (1.0 - alpha) * px + alpha * tx;
        ry = (1.0 - alpha) * py + alpha * ty;
        rz = (1.0 - alpha) * pz + alpha * tz;
    }

    // 7. Re-project onto unit sphere
    const double normR = std::sqrt(rx * rx + ry * ry + rz * rz);
    if (normR > 1e-9) {
        *outX = rx / normR;
        *outY = ry / normR;
        *outZ = rz / normR;
    } else {
        *outX = tx;
        *outY = ty;
        *outZ = tz;
    }
}

} // extern "C"
