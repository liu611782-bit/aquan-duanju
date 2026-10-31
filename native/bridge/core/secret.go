package core

// 阅读内容密钥：注册、持久化、正文解密。
//
// 密码学事实来自 fqapp 的实测实现（`rust/src/device/crypto.rs`、
// `rust/src/crypto.rs`）：
//   - 注册请求 = base64(iv‖AES-128-CBC-PKCS7(hex2bin(reverseHex(deviceId))))，
//     密钥是客户端内置的 rCXGfd2POMGzeiNIgo4iLg==；
//   - 响应 data.key = base64(iv‖AES-128-CBC(主密钥))，解出来才是真正的密钥；
//   - 正文 data.content = base64(iv‖AES-128-CBC(密钥))，明文可能是 gzip。
//
// 传输（签名、host、参数）在 `sdk/secretkey.go`，这里只管字节。

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/beilunyang/openhongguo/sdk"
)

const (
	// secretKeyMasterHex 解密 registerkey 响应里的 data.key。
	secretKeyMasterHex = "ac25c67ddd8f38c1b37a2348828e222e"
	// secretKeyRequestKeyB64 加密注册请求里的 device_id 材料。
	secretKeyRequestKeyB64 = "rCXGfd2POMGzeiNIgo4iLg=="

	// secretSidecarName 与设备档案同目录；不改 sdk 的 DeviceProfile 结构。
	secretSidecarName = "aquan_secret.json"

	aesBlock = 16
)

// profilePaths 记录每个客户端句柄对应的设备档案路径，密钥 sidecar 由它推导。
var profilePaths sync.Map

func rememberProfilePath(c *sdk.Client, profilePath string) {
	if c == nil || profilePath == "" {
		return
	}
	profilePaths.Store(c, profilePath)
}

func profilePathOf(c *sdk.Client) string {
	if v, ok := profilePaths.Load(c); ok {
		if s, ok := v.(string); ok {
			return s
		}
	}
	return ""
}

// reverseHexDeviceID 把十进制设备号格式化成 32 位 hex，再按字节对反转。
func reverseHexDeviceID(deviceID string) (string, error) {
	id := strings.TrimSpace(deviceID)
	if id == "" {
		return "", fmt.Errorf("%w: empty device id", sdk.ErrInvalidOptions)
	}
	n, err := strconv.ParseUint(id, 10, 64)
	if err != nil {
		return "", fmt.Errorf("%w: device id is not numeric: %q", sdk.ErrInvalidOptions, deviceID)
	}
	h := fmt.Sprintf("%032x", n)
	out := make([]byte, 0, len(h))
	for i := len(h); i >= 2; i -= 2 {
		out = append(out, h[i-2], h[i-1])
	}
	return string(out), nil
}

func pkcs7Pad(data []byte, blockSize int) []byte {
	pad := blockSize - len(data)%blockSize
	out := make([]byte, len(data)+pad)
	copy(out, data)
	for i := len(data); i < len(out); i++ {
		out[i] = byte(pad)
	}
	return out
}

func pkcs7Unpad(data []byte, blockSize int) ([]byte, error) {
	if len(data) == 0 || len(data)%blockSize != 0 {
		return nil, errors.New("pkcs7: not block aligned")
	}
	pad := int(data[len(data)-1])
	if pad == 0 || pad > blockSize || pad > len(data) {
		return nil, errors.New("pkcs7: bad padding length")
	}
	for _, b := range data[len(data)-pad:] {
		if int(b) != pad {
			return nil, errors.New("pkcs7: bad padding bytes")
		}
	}
	return data[:len(data)-pad], nil
}

func aesCBCEncrypt(key, iv, plain []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	if len(iv) != block.BlockSize() {
		return nil, fmt.Errorf("aes: iv must be %d bytes", block.BlockSize())
	}
	if len(plain)%block.BlockSize() != 0 {
		return nil, errors.New("aes: plaintext is not block aligned")
	}
	out := make([]byte, len(plain))
	cipher.NewCBCEncrypter(block, iv).CryptBlocks(out, plain)
	return out, nil
}

func aesCBCDecrypt(key, iv, ct []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	if len(iv) != block.BlockSize() {
		return nil, fmt.Errorf("aes: iv must be %d bytes", block.BlockSize())
	}
	if len(ct) == 0 || len(ct)%block.BlockSize() != 0 {
		return nil, errors.New("aes: ciphertext is not block aligned")
	}
	out := make([]byte, len(ct))
	cipher.NewCBCDecrypter(block, iv).CryptBlocks(out, ct)
	return out, nil
}

// encryptSecretKeyRequest 构造 registerkey 的 content 字段。
func encryptSecretKeyRequest(deviceID string) (string, error) {
	key, err := base64.StdEncoding.DecodeString(secretKeyRequestKeyB64)
	if err != nil || len(key) != aesBlock {
		return "", fmt.Errorf("%w: bad request key", sdk.ErrInvalidOptions)
	}
	hexID, err := reverseHexDeviceID(deviceID)
	if err != nil {
		return "", err
	}
	raw, err := hex.DecodeString(hexID)
	if err != nil {
		return "", fmt.Errorf("%w: %v", sdk.ErrInvalidOptions, err)
	}
	iv := make([]byte, aesBlock)
	if _, err := rand.Read(iv); err != nil {
		return "", err
	}
	enc, err := aesCBCEncrypt(key, iv, pkcs7Pad(raw, aesBlock))
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(append(iv, enc...)), nil
}

// decryptSecretKeyResponse 把 data.key 解成大写 hex 的内容密钥。
func decryptSecretKeyResponse(keyB64 string) (string, error) {
	key, err := hex.DecodeString(secretKeyMasterHex)
	if err != nil {
		return "", fmt.Errorf("%w: bad master key", sdk.ErrInvalidOptions)
	}
	blob, err := base64.StdEncoding.DecodeString(strings.TrimSpace(keyB64))
	if err != nil {
		return "", fmt.Errorf("%w: registerkey payload is not base64", sdk.ErrContentUnavailable)
	}
	if len(blob) < 2*aesBlock {
		return "", fmt.Errorf("%w: registerkey payload is too short", sdk.ErrContentUnavailable)
	}
	plain, err := aesCBCDecrypt(key, blob[:aesBlock], blob[aesBlock:])
	if err != nil {
		return "", fmt.Errorf("%w: %v", sdk.ErrContentUnavailable, err)
	}
	raw, err := pkcs7Unpad(plain, aesBlock)
	if err != nil || len(raw) == 0 {
		return "", fmt.Errorf("%w: registerkey padding", sdk.ErrContentUnavailable)
	}
	return strings.ToUpper(hex.EncodeToString(raw)), nil
}

// decryptChapterContent 解开一章正文；明文是 gzip 时顺带解压。
func decryptChapterContent(secretKeyHex, contentB64 string) ([]byte, error) {
	key, err := hex.DecodeString(strings.TrimSpace(secretKeyHex))
	if err != nil || len(key) != aesBlock {
		return nil, fmt.Errorf("%w: content key must be 16 bytes of hex", sdk.ErrContentUnavailable)
	}
	blob, err := base64.StdEncoding.DecodeString(strings.TrimSpace(contentB64))
	if err != nil {
		return nil, fmt.Errorf("%w: chapter content is not base64", sdk.ErrContentUnavailable)
	}
	if len(blob) <= aesBlock {
		return nil, fmt.Errorf("%w: chapter content is too short", sdk.ErrContentUnavailable)
	}
	plain, err := aesCBCDecrypt(key, blob[:aesBlock], blob[aesBlock:])
	if err != nil {
		return nil, fmt.Errorf("%w: %v", sdk.ErrContentUnavailable, err)
	}
	raw, err := pkcs7Unpad(plain, aesBlock)
	if err != nil {
		return nil, fmt.Errorf("%w: chapter padding", sdk.ErrContentUnavailable)
	}
	return gunzipIfNeeded(raw), nil
}

// gunzipIfNeeded 只在 gzip magic 存在时解压；解压失败按原文返回。
func gunzipIfNeeded(data []byte) []byte {
	if len(data) < 2 || data[0] != 0x1f || data[1] != 0x8b {
		return data
	}
	zr, err := gzip.NewReader(bytes.NewReader(data))
	if err != nil {
		return data
	}
	out, err := io.ReadAll(zr)
	_ = zr.Close()
	if err != nil {
		return data
	}
	return out
}

type secretFile struct {
	SecretKey string `json:"secretKey"`
	UpdatedAt string `json:"updatedAt"`
}

func secretSidecarPath(profilePath string) string {
	if profilePath == "" {
		return ""
	}
	return filepath.Join(filepath.Dir(profilePath), secretSidecarName)
}

func loadStoredSecret(profilePath string) string {
	path := secretSidecarPath(profilePath)
	if path == "" {
		return ""
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	var f secretFile
	if err := json.Unmarshal(raw, &f); err != nil {
		return ""
	}
	return strings.TrimSpace(f.SecretKey)
}

func storeSecret(profilePath, key string) error {
	path := secretSidecarPath(profilePath)
	if path == "" || key == "" {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	raw, err := json.Marshal(secretFile{
		SecretKey: key,
		UpdatedAt: time.Now().Format(time.RFC3339),
	})
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// contentSecretKey 返回设备的内容密钥；没有就注册一次并落盘。
func contentSecretKey(ctx context.Context, c *sdk.Client) (string, error) {
	profilePath := profilePathOf(c)
	if key := loadStoredSecret(profilePath); key != "" {
		return key, nil
	}
	deviceID, err := c.DeviceID(ctx)
	if err != nil {
		return "", err
	}
	content, err := encryptSecretKeyRequest(deviceID)
	if err != nil {
		return "", err
	}
	var lastErr error
	for attempt := 0; attempt < 3; attempt++ {
		cipherKey, err := c.RegisterSecretKey(ctx, content)
		if err != nil {
			lastErr = err
			continue
		}
		key, err := decryptSecretKeyResponse(cipherKey)
		if err != nil {
			lastErr = err
			continue
		}
		if err := storeSecret(profilePath, key); err != nil {
			lastErr = err
		}
		return key, nil
	}
	if lastErr == nil {
		lastErr = fmt.Errorf("%w: secret key registration failed", sdk.ErrContentUnavailable)
	}
	return "", lastErr
}

// decryptedChapter 取一章并解密；解密失败时弃用旧密钥重注册一次。
func decryptedChapter(ctx context.Context, c *sdk.Client, itemID string) (string, error) {
	cipherText, err := c.ChapterText(ctx, itemID)
	if err != nil {
		// 首次进书的第一击经常撞上设备冷启动/风控预热，第二击就能过
		//（实测：手动点重试必成功）。这里立即重试一次，省掉用户手动点。
		cipherText, err = c.ChapterText(ctx, itemID)
		if err != nil {
			return "", err
		}
	}
	if strings.TrimSpace(cipherText) == "" {
		return "", nil
	}
	key, err := contentSecretKey(ctx, c)
	if err != nil {
		return "", err
	}
	plain, err := decryptChapterContent(key, cipherText)
	if err == nil {
		return string(plain), nil
	}
	// 密钥可能已失效：删掉 sidecar 重新注册，再试一次。
	if path := secretSidecarPath(profilePathOf(c)); path != "" {
		_ = os.Remove(path)
	}
	key, rerr := contentSecretKey(ctx, c)
	if rerr != nil {
		return "", err
	}
	plain, derr := decryptChapterContent(key, cipherText)
	if derr != nil {
		return "", fmt.Errorf("%w: chapter decrypt failed", sdk.ErrContentUnavailable)
	}
	return string(plain), nil
}

// chapterText 取一章正文（小说文本或漫画图片清单的原始 JSON）。
func chapterText(ctx context.Context, c *sdk.Client, a []json.RawMessage) (any, error) {
	var itemID string
	if err := arg(a, 0, &itemID); err != nil {
		return nil, err
	}
	text, err := decryptedChapter(ctx, c, itemID)
	if err != nil {
		return nil, err
	}
	return map[string]any{"text": text}, nil
}
