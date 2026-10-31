# APP NVPTTT (CallLog)

Ứng dụng Android hỗ trợ nhân viên giao hàng quản lý nhật ký cuộc gọi, tin nhắn nhắc chuyển khoản, đối soát khoản chờ nhận và chụp/scan thông tin đơn.

## Tải và cập nhật

- **Tải APK mới nhất:** [GitHub Releases](https://github.com/thucdang0604/calllog-app/releases/latest)
- Ứng dụng kiểm tra phiên bản khi mở app hoặc quay lại foreground, tối đa một lần mỗi giờ. Nút biểu tượng cập nhật trên thanh trên cùng cho phép kiểm tra ngay; nếu có bản mới, app hiện hộp thoại tải APK.
- APK được tải ngầm để bạn vẫn sử dụng app bình thường. Khi tải xong, app hiện thông báo có nút **Cài đặt**; Android sẽ yêu cầu bạn xác nhận. Android có thể hỏi cho phép APP NVPTTT cài ứng dụng từ nguồn này.
- Dữ liệu cuộc gọi, thông tin đơn và ảnh được quản lý trên thiết bị. App chỉ gọi GitHub để kiểm tra thông tin phiên bản; không gửi dữ liệu khách hàng lên GitHub.

## Cài đặt

Tải `calllog.apk` từ trang Releases, mở tệp trên điện thoại Android và xác nhận cài đặt. Khi cập nhật, cài bản mới đè lên bản cũ để giữ dữ liệu trong ứng dụng.

## SMS ảo

SMS nhanh gửi số tiền trong popup luôn gửi thật qua SIM. SMS ảo chỉ dùng trong luồng mở SMS từ icon của GHN: có thể chọn tạo tin trong mục **Đã gửi** hoặc gửi thật qua SIM; tùy chọn tự động tạo SMS ảo cũng chỉ áp dụng cho luồng icon này. Tin ảo không được phát qua SIM nên khách không nhận được. Android sẽ yêu cầu chọn APP NVPTTT làm ứng dụng SMS mặc định trong chốc lát; sau khi tạo tin, hãy chọn lại ứng dụng SMS thường dùng trong màn Cài đặt để tiếp tục nhận SMS/MMS bình thường.

## Build từ mã nguồn

Yêu cầu Flutter stable và Android SDK. Chạy:

```bash
flutter pub get
flutter build apk --release
```

APK được tạo tại `build/app/outputs/flutter-apk/app-release.apk`.

## Phát hành bản mới

1. Tăng `version` trong `pubspec.yaml`, ví dụ `1.1.0+11`, rồi build APK bằng cùng môi trường/khoá ký hiện tại.
2. Tạo GitHub Release với tag tương ứng (ví dụ `v1.1.0`) và đính kèm APK với tên `calllog.apk`.
3. App sẽ phát hiện bản mới khi người dùng mở app.

APK release tiếp tục dùng khóa cũ tại `~/.android/debug.keystore` để Android cho phép cài đè lên bản đã phát hành. Nếu tệp khóa này không có, build release sẽ lỗi thay vì tự ký bằng khóa khác. Có thể cấu hình khóa khác bằng Gradle properties `CALLLOG_RELEASE_KEYSTORE`, `CALLLOG_RELEASE_STORE_PASSWORD`, `CALLLOG_RELEASE_KEY_ALIAS` và `CALLLOG_RELEASE_KEY_PASSWORD`; đổi khóa sẽ khiến Android từ chối cài đè nếu chưa có quy trình chuyển khóa. Không đưa keystore vào Git.
