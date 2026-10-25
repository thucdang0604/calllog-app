# APP NVPTTT (CallLog)

Ứng dụng Android hỗ trợ nhân viên giao hàng quản lý nhật ký cuộc gọi, tin nhắn nhắc chuyển khoản, đối soát khoản chờ nhận và chụp/scan thông tin đơn.

## Tải và cập nhật

- **Tải APK mới nhất:** [GitHub Releases](https://github.com/thucdang0604/calllog-app/releases/latest)
- Ứng dụng kiểm tra phiên bản khi mở app hoặc quay lại foreground, tối đa một lần mỗi giờ. Nút biểu tượng cập nhật trên thanh trên cùng cho phép kiểm tra ngay; nếu có bản mới, app hiện hộp thoại tải APK.
- Sau khi tải, mở tệp APK và xác nhận cài đặt. Android có thể yêu cầu cho phép cài ứng dụng từ trình duyệt.
- Dữ liệu cuộc gọi, thông tin đơn và ảnh được quản lý trên thiết bị. App chỉ gọi GitHub để kiểm tra thông tin phiên bản; không gửi dữ liệu khách hàng lên GitHub.

## Cài đặt

Tải `calllog.apk` từ trang Releases, mở tệp trên điện thoại Android và xác nhận cài đặt. Khi cập nhật, cài bản mới đè lên bản cũ để giữ dữ liệu trong ứng dụng.

## Build từ mã nguồn

Yêu cầu Flutter stable và Android SDK. Chạy:

```bash
flutter pub get
flutter build apk --release
```

APK được tạo tại `build/app/outputs/flutter-apk/app-release.apk`.

## Phát hành bản mới

1. Tăng `version` trong `pubspec.yaml`, ví dụ `1.0.8+9`, rồi build APK bằng cùng môi trường/khoá ký hiện tại.
2. Tạo GitHub Release với tag tương ứng (ví dụ `v1.0.8`) và đính kèm APK với tên `calllog.apk`.
3. App sẽ phát hiện bản mới khi người dùng mở app.

Giữ nguyên khóa ký hiện tại để Android cho phép cài đè lên bản cũ. Không đưa keystore vào Git.
