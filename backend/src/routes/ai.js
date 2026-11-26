const express = require('express');
const rateLimit = require('express-rate-limit');
const authMiddleware = require('../middleware/auth');

const router = express.Router();

// Yêu cầu đăng nhập hợp lệ trước khi gọi AI Proxy
router.use(authMiddleware);

// Giới hạn tốc độ riêng theo userId (sau khi đã qua authMiddleware): 20 req/phút/user
const aiUserLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 20,
  standardHeaders: true,
  legacyHeaders: false,
  keyGenerator: (req) => `ai_${req.userId}`,
  message: { error: 'Bạn đang gửi yêu cầu AI quá nhanh. Vui lòng thử lại sau ít giây.' },
});

router.use(aiUserLimiter);

function buildPrompt({ userInput, groups, wallets, locale, currentCurrency }) {
  const safeGroups = Array.isArray(groups) ? groups.slice(0, 100) : [];
  const safeWallets = Array.isArray(wallets) ? wallets.slice(0, 50) : [];

  const groupsMapping = safeGroups
    .map((g) => `${g.id}: ${g.name} (${g.type})`)
    .join('\n');
  const walletsMapping = safeWallets
    .map((w) => `${w.id}: ${w.name}`)
    .join('\n');

  const nowIso = new Date().toISOString();
  const currency = currentCurrency === 'USD' ? 'USD' : 'VND';

  if (locale === 'en') {
    return `You are a personal finance virtual assistant.
The user will input a natural language sentence. Please parse and extract the information into EXACTLY 1 JSON OBJECT.
DO NOT explain, DO NOT add any text other than the JSON.

List of categories (ID: Name (Type)):
${groupsMapping}

List of wallets (ID: Name):
${walletsMapping}

IMPORTANT - RULES:
1. Parse the EXACT amount the user mentioned. DO NOT do any currency math/multiply yourself. E.g. "1.5 USD" -> amount = 1.5. "100k" -> amount = 100000.
2. Identify currency ("USD" or "VND"). Default: "${currency}".
3. Identify exact wallet ID by name, else 0.
4. "intent": "addTransaction", "queryTransactions", or "createWallet".

JSON to return:
{
  "intent": "addTransaction" | "queryTransactions" | "createWallet",
  "amount": number,
  "currency": "USD" | "VND",
  "groupId": number,
  "walletId": number,
  "type": "expense" | "income",
  "note": string,
  "isRealTransaction": boolean,
  "date": "${nowIso}",
  "queryDateFrom": string | null,
  "queryDateTo": string | null,
  "walletName": string | null,
  "walletBalance": number
}

User input: ${JSON.stringify(userInput)}`;
  }

  return `Bạn là một trợ lý ảo phân tích chi tiêu cá nhân.
Người dùng sẽ nhập một câu nói tự nhiên. Hãy phân tích và trích xuất thông tin thành ĐÚNG 1 OBJECT JSON.
KHÔNG giải thích, KHÔNG thêm bất kỳ văn bản nào ngoài JSON.

Danh sách các nhóm (ID: Tên (Loại)):
${groupsMapping}

Danh sách các ví (ID: Tên):
${walletsMapping}

QUAN TRỌNG - NGUYÊN TẮC BÓC TÁCH:
1. Ghi nhận CHÍNH XÁC con số người dùng nói. KHÔNG tự đổi tỷ giá. Ví dụ: "1.5 đô" -> amount = 1.5, "50k" -> amount = 50000.
2. Nhận diện loại tiền tệ ("USD" hoặc "VND"). Nếu không nói rõ, mặc định là "${currency}".
3. Nhận diện ví dựa trên danh sách. Nếu không xác định, walletId = 0.
4. "intent": "addTransaction", "queryTransactions", hoặc "createWallet".

JSON cần trả về:
1. "intent": "addTransaction", "queryTransactions", hoặc "createWallet".
2. "amount": Số tiền chính xác (kiểu số). Nếu queryTransactions/createWallet, để 0.
3. "currency": "USD" hoặc "VND".
4. "groupId": ID nhóm phù hợp nhất (mặc định 1 nếu không rõ).
5. "walletId": ID ví thanh toán (mặc định 0).
6. "type": "expense" hoặc "income".
7. "note": Ghi chú ngắn gọn.
8. "isRealTransaction": true nếu là giao dịch hoặc tạo ví, false nếu chào hỏi/spam.
9. "date": Ngày giao dịch chuẩn ISO-8601 dựa trên hôm nay là ${nowIso}.
10. "queryDateFrom": Ngày bắt đầu nếu queryTransactions (00:00:00).
11. "queryDateTo": Ngày kết thúc nếu queryTransactions (23:59:59).
12. "walletName": Tên ví mới nếu createWallet.
13. "walletBalance": Số dư ban đầu của ví nếu createWallet (mặc định 0).

Câu nói: ${JSON.stringify(userInput)}`;
}

// POST /ai/parse-transaction
router.post('/parse-transaction', async (req, res) => {
  try {
    const rawKey = (process.env.GEMINI_API_KEY || '').replace(/['"]/g, '').trim();
    if (!rawKey) {
      return res.status(503).json({ error: 'AI_NOT_CONFIGURED' });
    }

    const { userInput, groups, wallets, locale, currentCurrency } = req.body || {};
    if (!userInput || typeof userInput !== 'string' || userInput.trim().length === 0) {
      return res.status(400).json({ error: 'Dữ liệu đầu vào không hợp lệ' });
    }
    if (userInput.length > 1000) {
      return res.status(400).json({ error: 'Câu nhập quá dài (tối đa 1000 ký tự)' });
    }

    const prompt = buildPrompt({
      userInput: userInput.trim(),
      groups,
      wallets,
      locale,
      currentCurrency,
    });

    const attempts = [
      { version: 'v1beta', model: 'gemini-2.5-flash' },
      { version: 'v1beta', model: 'gemini-2.0-flash' },
      { version: 'v1', model: 'gemini-2.0-flash' },
    ];

    for (const { version, model } of attempts) {
      const url = `https://generativelanguage.googleapis.com/${version}/models/${model}:generateContent?key=${encodeURIComponent(rawKey)}`;
      try {
        const response = await fetch(url, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            contents: [{ parts: [{ text: prompt }] }],
            generationConfig: { responseMimeType: 'application/json' },
          }),
          signal: AbortSignal.timeout(15000),
        });

        if (response.ok) {
          const jsonBody = await response.json();
          const text = jsonBody?.candidates?.[0]?.content?.parts?.[0]?.text;
          if (text) {
            const cleaned = text.replace(/```json/g, '').replace(/```/g, '').trim();
            const parsed = JSON.parse(cleaned);
            return res.json({ result: parsed });
          }
        }
      } catch (_) {
        // Thử model dự phòng tiếp theo
      }
    }

    return res.status(502).json({ error: 'Không thể kết nối dịch vụ AI lúc này' });
  } catch (err) {
    console.error('AI parse error:', err.message);
    return res.status(500).json({ error: 'Lỗi hệ thống' });
  }
});

// POST /ai/scan-receipt — Multimodal Vision OCR + QR Extraction cho cả Chrome Web & Mobile
router.post('/scan-receipt', async (req, res) => {
  try {
    const rawKey = (process.env.GEMINI_API_KEY || '').replace(/['"]/g, '').trim();
    if (!rawKey) {
      return res.status(503).json({ error: 'AI_NOT_CONFIGURED' });
    }

    const { imageBase64, mimeType } = req.body || {};
    if (!imageBase64 || typeof imageBase64 !== 'string' || imageBase64.length < 32) {
      return res.status(400).json({ error: 'Ảnh hóa đơn không hợp lệ' });
    }
    if (imageBase64.length > 5.5 * 1024 * 1024) {
      return res.status(413).json({ error: 'Ảnh hóa đơn quá lớn (tối đa ~4MB)' });
    }

    const safeMime = ['image/jpeg', 'image/png', 'image/webp'].includes(mimeType)
      ? mimeType
      : 'image/jpeg';

    const visionPrompt = `Bạn là hệ thống OCR và đọc mã QR hóa đơn chi tiêu tiếng Việt độ chính xác cao.
Hãy đọc toàn bộ văn bản biên lai VÀ mã QR (VietQR 000201..., QR hóa đơn điện tử GDT) nếu có trong ảnh.
CHỈ trả về ĐÚNG 1 JSON OBJECT theo cấu trúc sau, KHÔNG giải thích thêm:
{
  "totalAmount": number (tổng số tiền thanh toán quy đổi ra VND nguyên, ví dụ 125000; để 0 nếu không tìm thấy),
  "merchantName": string | null (tên cửa hàng, siêu thị, quán cafe hoặc đơn vị thụ hưởng),
  "transactionDate": string | null (định dạng YYYY-MM-DD nếu có trên hóa đơn),
  "invoiceCode": string | null (số hóa đơn / mã đơn hàng nếu có),
  "description": string | null (tóm tắt mặt hàng hoặc nội dung thanh toán ngắn gọn),
  "qrPayload": string | null (chuỗi dữ liệu thô của mã QR nếu đọc được),
  "rawText": string (toàn bộ nội dung chữ đọc được từ ảnh),
  "confidence": number (từ 0.0 đến 1.0)
}`;

    const attempts = [
      { version: 'v1beta', model: 'gemini-2.5-flash' },
      { version: 'v1beta', model: 'gemini-2.0-flash' },
      { version: 'v1', model: 'gemini-2.0-flash' },
    ];

    for (const { version, model } of attempts) {
      const url = `https://generativelanguage.googleapis.com/${version}/models/${model}:generateContent?key=${encodeURIComponent(rawKey)}`;
      try {
        const response = await fetch(url, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            contents: [
              {
                parts: [
                  { text: visionPrompt },
                  { inlineData: { mimeType: safeMime, data: imageBase64 } },
                ],
              },
            ],
            generationConfig: { responseMimeType: 'application/json' },
          }),
          signal: AbortSignal.timeout(20000),
        });

        if (response.ok) {
          const jsonBody = await response.json();
          const text = jsonBody?.candidates?.[0]?.content?.parts?.[0]?.text;
          if (text) {
            const cleaned = text.replace(/```json/g, '').replace(/```/g, '').trim();
            const parsed = JSON.parse(cleaned);
            return res.json({ result: parsed });
          }
        }
      } catch (_) {
        // Thử model dự phòng tiếp theo
      }
    }

    return res.status(502).json({ error: 'Không thể phân tích ảnh qua dịch vụ AI lúc này' });
  } catch (err) {
    console.error('AI scan-receipt error:', err.message);
    return res.status(500).json({ error: 'Lỗi hệ thống khi xử lý ảnh hóa đơn' });
  }
});

module.exports = router;
