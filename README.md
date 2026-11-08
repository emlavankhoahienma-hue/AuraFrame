# AuraFrame 📸
> **Camera Nhiếp Ảnh Bố Cục Thông Minh & Bám Mục Tiêu Không Gian 3D Thời Gian Thực**
> *Hỗ trợ iOS 17+, Swift 5.9, C++20 Native Engine, Apple Vision & CoreMotion 200Hz Sensor Fusion*

---

## 🌟 Giới thiệu tổng quan
**AuraFrame** là một ứng dụng camera nhiếp ảnh chuyên nghiệp dành cho iOS 17+, kết hợp giữa thị giác máy tính Apple Vision nơ-ron và cảm biến chuyển động con quay hồi chuyển CoreMotion tần số cao (200Hz). Ứng dụng giúp người dùng chụp ảnh và quay video với bố cục hoàn hảo như một nhiếp ảnh gia chuyên nghiệp thông qua cơ chế bám mục tiêu không gian 3D.

---

## 📐 Kiến trúc & Các tính năng cốt lõi

### 1. Hạ tầng C++20 Native (200Hz Ring Buffer & Geodesic SLERP $S^2$)
- Vòng đệm tròn 640 mẫu `NTCMotionSample` đồng bộ với con quay hồi chuyển 200Hz.
- Thuật toán `ntc_s2_1euro_slerp`: Lọc mượt One-Euro trên tiếp diện mặt cầu đơn vị $S^2$, triệt tiêu rung giật bàn tay mà vẫn giữ độ phản hồi nhanh khi xoay máy:
  $$\text{cutoffHz} = 14.0 + \min(85.0, \theta \cdot \text{focalScale} \cdot 120.0)$$

### 2. Động cơ Bố cục Đa giả thuyết (Multi-Hypothesis Photographic Composition)
- Tự động so sánh cùng lúc 4 quy tắc kinh điển:
  1. **Quy tắc 1/3 (Rule of Thirds)**: Tọa độ $1/3$ và $2/3$.
  2. **Tỷ lệ vàng (Golden Ratio / Phi Grid)**: $0.382$ và $0.618$.
  3. **Đối xứng trung tâm (Center Symmetry)**: $(0.5, 0.5)$.
  4. **Đường dẫn thị giác (Diagonal Leading Lines)**: Hướng mắt nhìn vào chủ thể.
- Tính điểm ngắm Aim Point:
  $$P_{target} = \left(0.5 + (S_{anchor}.x - P_{grid}.x), \; 0.5 + (S_{anchor}.y - P_{grid}.y)\right)$$
- Thưởng điểm khoảng thở hướng nhìn (**Looking Room Bonus**) và khoảng thở trên đầu (**Headroom Fit**).

### 3. Bám mục tiêu không gian thực (Handheld Spatial Tracking & Parallax Correction)
- **Error-State Kalman Filter (ESKF)** trên tiếp diện $(\mathbf{e}_1, \mathbf{e}_2)$: Damping tay người $\boldsymbol{\omega}_{t+\Delta t} = \boldsymbol{\omega}_t \cdot \exp(-2.85 \Delta t)$.
- Cổng Mahalanobis Gating: Kiểm soát sai số quang học và quán tính.
- **Phục hồi thị sai Parallax do bước chân**: Tự động re-identify bộ lọc và dùng Geodesic SLERP kéo êm tâm vàng về chủ thể thật khi người chụp di chuyển.

### 4. Tự động Zoom thông minh (AI Smart Windowed Zoom)
- Đấu loại khung cắt ảo theo tỷ lệ diện tích:
  $$\rho = \frac{\text{Area}(S_{box})}{\text{Area}(\text{Frame})}$$
- Tự động ramp zoom quang học phần cứng ($0.5x, 1x, 2x, 5x$) qua `AVCaptureDevice.ramp`.

### 5. Khung ngắm AR SwiftUI Chuyên nghiệp
- Lưới bố cục mờ, sóng quét Radar Scan Wave.
- Tâm ngắm vàng 3D (`#FFD700`, 36pt, 4 vạch vi chữ thập) chuyển xanh ngọc bích khi đạt chuẩn bố cục.
- Neo mép màn hình (**Edge Docking**) kèm mũi tên chỉ hướng khi mục tiêu trôi ra ngoài màn hình.
- Thước cân bằng chân trời ảo (**Virtual Horizon Leveler**) đo góc nghiêng Roll chính xác đến $0.5^\circ$.
- Thanh trượt phơi sáng mặt trời (**Sun Slider**) vuốt trực tiếp từ $-2.0\text{ EV}$ đến $+2.0\text{ EV}$.
- Hỗ trợ cả 2 chế độ **Chụp Ảnh** và **Quay Video**!

---

## 🛠 Hướng dẫn biên dịch & Sideload

### Yêu cầu môi trường
- macOS Sonoma (14.0+) với **Xcode 15.4** hoặc **Xcode 16.0+**.
- iPhone vật lý chạy **iOS 17.0+** (để hỗ trợ camera intrinsics và 60 FPS video pipeline).

### Build bằng dòng lệnh (CLI)
```bash
xcodebuild archive \
  -project AuraFrame.xcodeproj \
  -scheme AuraFrame \
  -configuration Release \
  -archivePath build/AuraFrame.xcarchive \
  -destination "generic/platform=iOS" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  AD_HOC_CODE_SIGNING_ALLOWED=YES
```

### Đóng gói file unsigned `.ipa` để cài qua Sideloadly / TrollStore
```bash
mkdir -p build/Payload
cp -R build/AuraFrame.xcarchive/Products/Applications/AuraFrame.app build/Payload/
cd build
zip -r AuraFrame-unsigned.ipa Payload
cd ..
```

---

## 📄 Bản quyền & Tác giả
- Phát triển bởi **Principal Systems Architect & Computer Vision Lead Engineer**.
- Tuân thủ nguyên tắc **Strict Boundary** & **Honest Engineer**.
