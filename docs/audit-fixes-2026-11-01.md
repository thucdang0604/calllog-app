# Khắc phục sau audit 2026-11-01

Ưu tiên chi phí thấp: không thêm dịch vụ Firebase có phí cố định. Kiểm tra bằng Firestore emulator và thiết bị Android trước khi phát hành.

## Thực hiện trong đợt này

| Mục audit | Công việc | Trạng thái |
| --- | --- | --- |
| 1 | Giảm ghi Firestore từ đồng bộ công khai, siết giới hạn API ghi | Đã deploy; emulator và đồng bộ live đạt |
| 2 | Không cho thoát khi app còn giữ vai trò SMS mặc định | APK build đạt; chờ thử trên thiết bị |
| 6 | Chặn tạo/duyệt đơn mới vô ích cho máy đã có gói vĩnh viễn | Đã deploy; emulator đạt, chưa thử thanh toán live |
| 7 | Sắp đơn quản trị theo thời gian tạo | Đã deploy; emulator đạt, chưa thử đăng nhập web live |
| 8 | Truy vấn đúng đơn chờ trong bot và tìm license trên toàn dữ liệu | Đã deploy; emulator đạt, chưa thử đăng nhập web live |
| 11 | Xuất/khôi phục lịch sử đối soát; hướng dẫn sao lưu khóa ký APK | Emulator xuất/nhập đạt; chờ thử thiết bị thật và nơi lưu khóa ngoài máy |
| 13 | Kiểm tra tự động các luồng bản quyền và checklist thiết bị | Backend 8/8, Flutter 3/3, APK release build đạt; chờ thử thiết bị |
| 14 | Bỏ phụ thuộc và mã không dùng | Hoàn thành; 2 gói thực tế rời lockfile |

## Theo quyết định của chủ dự án

- Loại khỏi đợt này: 3 (đơn vị số tiền), 4 (ghép SMS trả lời), 5 (thay ảnh chứng từ).
- Cần giải thích trước khi quyết định: 9 (SMS dài), 10 (thông báo chủ động cho quản lý), 12 (tài khoản Firebase Auth khác với quyền quản trị).

Không đưa keystore, mật khẩu hoặc dữ liệu khách hàng vào Git.

APK thử nghiệm `1.0.27+28` đã build bằng cùng chứng chỉ với release `v1.0.26`. Chưa đăng GitHub Release vì kiểm tra vai trò SMS và khôi phục bản sao trên máy thật chưa hoàn tất.
SHA-256 của APK thử nghiệm: `1650A3BD5050F935A71408ADFD42FBF4B5870C331C2A1870032843BB0E804422`.

Emulator Android 16: xuất bản sao 4 khoản, nhập lại bỏ qua 4 khoản đã có, nhập bản sao thử thêm 1 khoản rồi xóa đúng khoản thử. Bản sao cũ thiếu trường `channel` đã được sửa để nhập được; khi xuất mới, khoản SMS cũ được ghi rõ `channel=sms`.

## Làm rõ các mục chưa triển khai

- **9 — SMS dài:** Luồng gửi SMS thật từ cửa sổ nổi dùng `sendTextMessage`, còn màn xử lý SMS từ ứng dụng khác đã có cách chia nhiều phần. Đây là SMS qua SIM của người dùng, không liên quan SMS kích hoạt bản quyền. Nếu tự chia nhiều phần, nhà mạng có thể tính cước nhiều tin. Quyết định cần chọn: giới hạn mẫu vào một phần với cảnh báo, hoặc cho gửi nhiều phần kèm xác nhận số phần.
- **10 — Thông báo cho quản lý:** Web quản trị hiện chỉ cập nhật khi tải lại; bot cũng chỉ báo khi chủ tài khoản gọi `/choxacnhan`. Phương án ít mã và ít lượt Firebase nhất là gửi một tin Telegram cho chủ tài khoản khi khách liên kết đơn lần đầu, có chống gửi lặp. Biểu tượng thông báo ghim trên màn hình là một luồng khác, cần quyền thông báo và cơ chế push/polling; chưa triển khai.
- **12 — Một tài khoản quản lý:** Backend đã kiểm tra email Google `thucdang2205@gmail.com` trên mọi API quản trị. Firebase Auth vẫn có thể tạo bản ghi cho người khác trước khi web từ chối và thử xóa; họ không có quyền quản trị. Chặn việc tạo bản ghi Auth ngay từ đầu cần giải pháp nhận dạng riêng và đánh giá chi phí, nên chưa thay đổi luồng đăng nhập.
