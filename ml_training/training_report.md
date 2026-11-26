# 📊 Báo Cáo Huấn Luyện & Đánh Giá Mô Hình Học Máy (OneMoreCoin)

## 1. Mô hình Phân loại Danh mục Chi tiêu (TF-IDF + Multinomial Naive Bayes)

- **Tổng số mẫu dữ liệu:** `2420` mẫu (11 danh mục chi tiêu)
- **Tập huấn luyện (Train 80%):** `1936` mẫu
- **Tập kiểm thử (Test 20%):** `484` mẫu
- **Kích thước từ điển đặc trưng (Vocabulary Size):** `1200` N-grams
- **Độ chính xác tổng thể (Test Accuracy):** **93.80%**
- **Macro Precision:** **95.26%**
- **Macro Recall:** **93.80%**
- **Macro F1-Score:** **93.74%**

### Bảng Đánh Giá Chi Tiết Theo Từng Danh Mục (Classification Report)

| Danh mục (Category) | Precision | Recall | F1-Score | Số mẫu Test (Support) |
| :--- | :---: | :---: | :---: | :---: |
| **Di chuyển** | 67.19% | 97.73% | **79.63%** | 44 |
| **Giải trí** | 100.00% | 93.18% | **96.47%** | 44 |
| **Mua sắm** | 100.00% | 63.64% | **77.78%** | 44 |
| **Sức khỏe** | 97.78% | 100.00% | **98.88%** | 44 |
| **Tiền học** | 100.00% | 100.00% | **100.00%** | 44 |
| **Tiền internet** | 100.00% | 100.00% | **100.00%** | 44 |
| **Tiền nhà** | 100.00% | 100.00% | **100.00%** | 44 |
| **Tiền nước** | 95.65% | 100.00% | **97.78%** | 44 |
| **Tiền điện** | 93.62% | 100.00% | **96.70%** | 44 |
| **Tiền điện thoại** | 93.62% | 100.00% | **96.70%** | 44 |
| **Ăn uống** | 100.00% | 77.27% | **87.18%** | 44 |

## 2. Đánh giá Mô hình Dự báo Chi tiêu (Financial Time-Series Forecasting)

Thử nghiệm trên 100 kịch bản chi tiêu thực tế (bao gồm hóa đơn cố định đầu tháng và biến thiên cuối tuần):

| Phương pháp Dự báo | Sai số phần trăm tuyệt đối trung bình (MAPE) | Đánh giá |
| :--- | :---: | :--- |
| **Baseline (Daily Burn Rate thuần túy)** | `46.66%` | Dễ bị nhiễu khi có khoản chi lớn đầu tháng (tiền nhà, điện nước) |
| **Hybrid (MAD Outlier Filtering + OLS Trend + EWMA)** | **`3.36%`** | Giảm mạnh sai số nhờ lọc khoản chi đột biến và bắt xu hướng |
