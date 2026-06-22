# Strivory iCloud 备份与恢复

## 产品边界

Strivory 的 iCloud 功能备份应用自身保存的数据：已读取的 Workout 快照、CSV 导入批次、导入策略和导出显示名称。它不会向 Apple 健康写入任何数据。

删除应用会移除本机缓存；使用同一 Apple ID 重新安装后，用户可从 CloudKit 私有数据库恢复备份，再重新授权 Apple 健康以刷新当前 Workout。

## 一次性 Apple 配置

项目使用容器 `iCloud.com.pananq.strivory` 和 CloudKit 私有数据库。首次连接真机或提交包含此功能的构建前，请在 Xcode 的 Signing & Capabilities 中确认：

1. 已为目标启用 **iCloud** capability。
2. 勾选 **CloudKit**，并选择 `iCloud.com.pananq.strivory`。
3. 在 Apple Developer 的 Identifiers 页面确认该容器已关联 `com.pananq.strivory.app`。
4. 在 CloudKit Dashboard 的 Development 环境运行一次应用并开启备份，以创建 `StrivoryBackup` record type；验证后将 schema 部署至 Production。
5. 重新生成包含 iCloud capability 的 App Store provisioning profile，再归档上传。

## 验收场景

1. 导入 CSV、同步 Apple 健康后，在“设置”开启“iCloud 备份与恢复”。
2. 确认状态变为“已同步”。
3. 删除应用并重新安装，使用同一 Apple ID 打开。
4. 出现“发现 iCloud 备份”提示，选择“恢复备份”。
5. 年历立即显示备份快照；重新授权 Apple 健康后，当前 Workout 被重新读取并去重。

## 隐私维护

开启备份会将用户选择的运动数据传输到 Apple 的私有 iCloud 空间。因此每次发布包含该功能的版本前，都必须重新核对 App Store Connect 的 App Privacy 声明和公开隐私政策。
