# Sao lưu và kiểm tra trước khi phát hành

## Lịch sử đối soát trên Android

Trong **Đối soát chuyển khoản**, mở menu sao lưu ở thanh trên:

1. **Xuất bản sao đối soát** tạo một tệp ZIP gồm các khoản và ảnh còn tồn tại. App báo số ảnh cũ đã mất nếu có.
2. Cất ZIP ở nơi riêng tư. Tệp chứa số điện thoại, nội dung SMS và ảnh, **không được mã hóa**. Không đưa vào Git hoặc gửi cho khách.
3. **Khôi phục từ bản sao** chỉ thêm khoản chưa có theo ID, không ghi đè khoản hiện tại. Có thể nhập lại cùng tệp mà không nhân đôi khoản.

Bản sao tối đa 500 MiB, tối đa 20.000 khoản và 20 MiB mỗi ảnh. Bản sao không chứa license hay cài đặt tài khoản ngân hàng; license sẽ đồng bộ lại theo mã máy. QR ở bộ nhớ đệm có thể đã bị Android dọn trước khi xuất.

## Khóa ký APK

APK hiện tại dùng `~/.android/debug.keystore`. SHA-256 của tệp khóa trên máy phát hành tại ngày 2026-11-01:

`4B9A925CBD2CD7F18BC67D08D23C3DE025231B364A28A5298384DDA968952EE5`

Sao chép **đúng tệp này** sang ổ ngoài hoặc kho mã hóa nằm ngoài ổ máy làm việc. Sau khi sao chép, so sánh SHA-256 của hai tệp bằng `Get-FileHash -Algorithm SHA256`. Giữ mật khẩu và đường dẫn khôi phục ở nơi riêng; không đưa keystore vào Git. Trước lần phát hành tiếp theo, kiểm tra khóa còn đúng SHA-256 trên.

Khi có nơi lưu, thay đường dẫn `E:\private\calllog-debug.keystore` bên dưới bằng đường dẫn thật trong ổ hoặc kho đã mã hóa, tạo thư mục đích rồi chạy PowerShell:

```powershell
$sourceKey = Join-Path $env:USERPROFILE '.android\debug.keystore'
$backupKey = 'E:\private\calllog-debug.keystore'
Copy-Item -LiteralPath $sourceKey -Destination $backupKey
(Get-FileHash -LiteralPath $sourceKey -Algorithm SHA256).Hash
(Get-FileHash -LiteralPath $backupKey -Algorithm SHA256).Hash
```

Hai chuỗi SHA-256 phải giống nhau và bằng giá trị ở trên. Không đổi khóa ký trước khi có kế hoạch cập nhật cho các APK đang cài trên máy khách.

## Kiểm tra trên một máy Android thử nghiệm

- Tạo SMS ảo rồi bấm Back khi app đang kiểm tra lượt dùng thử; xác nhận app vẫn yêu cầu trả vai trò SMS mặc định trước khi thoát.
- Bấm Back sau khi cấp vai trò SMS trong màn xử lý SMS từ ứng dụng khác; xác nhận app mở màn khôi phục. Thử cả lúc mất mạng.
- Tạo một khoản đối soát có ảnh, xuất ZIP, xóa khoản **trên máy thử nghiệm**, nhập ZIP, kiểm tra khoản và ảnh khôi phục. Nhập lại để xác nhận không nhân đôi.
- Với một mã máy thử: tạo đơn, gửi thông tin cho bot, quản lý đối soát và duyệt, mở app để đồng bộ. Duyệt lại không được cộng thêm hạn; gói vĩnh viễn không cho tạo đơn mới.
- Trên web, kiểm tra đơn vừa tạo nằm đầu danh sách, tìm mã máy đầy đủ dù chưa tải các trang còn lại. Trong bot, `/choxacnhan` phải hiện đơn chờ cũ dù có nhiều đơn đã duyệt mới hơn.

Không thử bằng khoản chuyển tiền thật trước khi luồng emulator và thiết bị thử nghiệm đều đạt.
