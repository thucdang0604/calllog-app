# Hướng dẫn cài đặt và cập nhật

## Cài đặt

1. Tải APK tại [GitHub Releases](https://github.com/thucdang0604/calllog-app/releases/latest).
2. Mở `calllog.apk` trên điện thoại Android.
3. Nếu được hỏi, cho phép trình duyệt cài ứng dụng không rõ nguồn.
4. Xác nhận cài đặt và cấp quyền theo nhu cầu sử dụng.

## Cập nhật

Khi mở ứng dụng hoặc quay lại app, app kiểm tra GitHub Releases tối đa một lần mỗi giờ. Nút cập nhật trên thanh trên cùng sẽ kiểm tra ngay. Nếu có bản mới, chọn **Tải cập nhật**, mở APK vừa tải và xác nhận cài đặt đè lên bản cũ.

## Build từ mã nguồn

```bash
flutter pub get
flutter build apk --release
```

## Phát hành

Tăng version trong `pubspec.yaml`, build bằng cùng khóa ký hiện tại, sau đó tạo GitHub Release với tag `v<version>` (ví dụ `v1.0.9`) và đính kèm APK tên `calllog.apk`. App tự nhận ra phiên bản mới khi người dùng mở app. Không lưu keystore trong repository.
