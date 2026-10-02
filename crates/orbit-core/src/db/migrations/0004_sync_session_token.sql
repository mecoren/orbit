-- 0004：sync_configs 增加 S3 STS 会话令牌列（F80，2026-10-01 第六轮）
-- STS 临时凭据场景需要 security token 参与签名；长期 AK/SK 用户留空即可。
ALTER TABLE sync_configs ADD COLUMN session_token TEXT NOT NULL DEFAULT '';  -- S3 STS 会话令牌（空=长期凭据）
