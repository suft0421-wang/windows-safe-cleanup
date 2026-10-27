# Windows Safe Cleanup

从一次 Windows 磁盘整理任务归纳的 PowerShell 实战项目：先查占用，再清理明确可再生成的缓存；虚拟机先做完整压缩备份、核对清单与哈希，再移除原件。

公开版本默认只预览，必须明确指定 -Apply 才执行清理。示例虚拟机配置默认禁用。仓库只包含代码、说明和测试，没有个人日志、虚拟磁盘、备份或登录凭据。

## 包含内容

| 文件 | 用途 |
| --- | --- |
| Inspect-Storage.ps1 | 统计文件夹占用、大文件与无法访问的目录 |
| Clean-Cache.ps1 | 清理已知应用目录内超过指定天数的旧缓存、更新下载与崩溃转储 |
| Backup-RemoveVM.ps1 | 本次实战流程的配置化参考：三台独立 VMware 虚拟机和一个 WSL2 分发 |
| config/vm.example.json | 虚拟机示例配置；使用前复制为 vm.local.json 并修改 |
| tests/Run-Tests.ps1 | 临时目录内的备份、损坏检测、还原及缓存清理测试 |
| docs/CASE-STUDY.md | 本次实战结果和踩坑复盘 |
| docs/RESTORE.md | 从完整压缩备份恢复内容 |
| docs/UPLOAD.md | 上传公开仓库前的文件清单和步骤 |

## 环境

Windows 10/11，Windows PowerShell 5.1 或 PowerShell 7。虚拟机备份与测试需要自行安装 7-Zip；不在仓库中附带第三方二进制程序。

脚本不自动请求管理员权限。没有权限、文件被占用、原件变化或备份不完整时会跳过或停止，并记录原因。

## 先看占用

只读扫描，不读取文档内容：

    .\Inspect-Storage.ps1 -Path C:\ -OutputPath .\runs\storage.json

报告含本机路径，属于私人运行数据，不应上传。

## 缓存清理

默认预览：

    .\Clean-Cache.ps1 -NoPause

核对结果后执行：

    .\Clean-Cache.ps1 -Apply -MinimumAgeDays 7

只处理脚本内明确列出的缓存目录。不会清理下载文件夹、个人文档、微信附件、WPS备份、虚拟磁盘、Windows Installer 或系统组件目录。保留最近文件，按应用限制安装包和崩溃转储的扩展名；拒绝跟随目录链接。

UserProfilePath 和 ProgramDataPath 参数主要用于适配配置与临时目录测试，不会修改系统环境变量。

## 虚拟机流程的范围

这是本次“三台 VMware 加一个 WSL2”流程的参考实现，不是通用虚拟机管理器。VMware 虚拟磁盘必须是无父磁盘的分片稀疏 VMDK；配置文件必须位于独立的虚拟机目录。虚拟机不要存放在整个桌面、文档或磁盘根目录中。

本次模型以 VMware 数据位于 D 盘、WSL2 数据位于 C 盘、备份保存到 D 盘为基础。修改其他布局前，需要相应验证空间调度逻辑。脚本没有自动断点续传功能；中断后应保留报告和已验证备份，不要盲目重跑或手工删除剩余数据。

1. 复制 config/vm.example.json 为 config/vm.local.json。
2. 填入三台虚拟机的专用目录、vmx、VMDK描述文件路径，以及准确的 WSL 分发名称。
3. 指定 BackupDirectory，必要时指定 SevenZipPath。确认配置后将 Enabled 改为 true。
4. 正常关闭 VMware 虚拟机和主窗口，然后预览：

    .\Backup-RemoveVM.ps1 -ConfigPath .\config\vm.local.json -NoPause

明确执行：

    .\Backup-RemoveVM.ps1 -ConfigPath .\config\vm.local.json -Apply

每台依次执行：锁定源文件并计算 SHA256 → 创建完整压缩备份 → 测试压缩包 → 核对文件清单与大小 → 再次核验源内容 → 移除原件。跨盘保存备份时再做 SHA256 核对，确认后才清除暂存副本。

WSL 使用注册信息匹配准确的分发；只停止和注销目标分发。虚拟机内的系统、数据库与工作文件都保存在备份里，没有自动挑选哪些内部文件重要。

完整压缩可能需要数十分钟甚至数小时。默认压缩级别为1，偏向速度；提高级别可能更慢。净释放空间 = 原件占用 - 最终备份占用，不能把全部原始大小当成节省空间。

## 脚本执行策略

如果 Windows 提示禁止运行脚本，可以只为当前 PowerShell 进程允许本次脚本，不修改用户或系统的永久策略。以下仍然只是预览：

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Clean-Cache.ps1 -NoPause

需要执行时仍必须明确加 -Apply。不要将全局策略改为无限制来运行本项目。

## 测试

    .\tests\Run-Tests.ps1 -SevenZipPath 'C:\Program Files\7-Zip\7z.exe'

测试只在新建的临时目录中创建和删除夹具。验证：

- 完整压缩包、中文和空格路径、源文件哈希与解压还原一致。
- 损坏的备份阻止删除。
- 即使大小和修改时间相同，源内容变化也能被 SHA256 检测。
- 源目录外的项目文件保持不变，禁止将整个磁盘当作虚拟机源目录。
- 默认缓存预览不删除文件；显式执行只删除老旧且符合规则的夹具文件。
- WSL 参数不会被多余引号错误解释为 Linux 命令；兼容 UTF-8 与 UTF-16 输出。

GitHub Actions 只运行临时夹具测试，不操作实际虚拟机。

## 本次实战结果

缓存清理约9.24 GB。虚拟机原件约92.45 GB，完整压缩备份约43.49 GB，虚拟机阶段净释放约48.96 GB。两部分合计约58.2 GB。

这些是一次机器上的实测结果，不代表其他机器能释放同样空间。本文 GB 沿用 PowerShell 的1GB单位，即2^30字节。
