# 从完整备份取回文件

不要删除唯一一份已验证的压缩备份。备份目录中的 metadata 保存源文件清单与 SHA256；压缩包是完整虚拟机内容，没有按文件类型自动挑选工作成果。

## 先核对压缩包

    & 'C:\Program Files\7-Zip\7z.exe' t 'D:\VMBackups\某次备份\main-full.7z'
    Get-FileHash -Algorithm SHA256 -LiteralPath 'D:\VMBackups\某次备份\main-full.7z'

将得到的哈希与对应 completed.json 或 verified-backup.json 中记录的哈希比较。压缩包损坏或哈希不符时先保留现有文件，不覆盖其他副本。

## VMware

压缩包内保留相对于原源磁盘根目录的路径。先解压到一个新的恢复目录，不要覆盖正在使用的文件。查看源清单，按原布局放回 vmx、磁盘描述文件与所有分片，然后由 VMware 打开 vmx。

磁盘描述文件可能与 vmx 不在同一目录，因此不能只恢复其中一个文件。共享文件夹指向的 Windows 文件并没有包含在虚拟磁盘里；脚本不删除这些外部个人文件。

## WSL2

将压缩包中的 ext4.vhdx 解压到一个新的、足够大的目录。可以使用一个新的分发名称就地导入：

    wsl --import-in-place RecoveredLinux 'D:\RecoveredLinux\ext4.vhdx'

默认用户和其他设置可参考 metadata 中的原注册信息。不要对任何尚未备份的分发运行 unregister。

参考：[Microsoft WSL 基本命令](https://learn.microsoft.com/zh-cn/windows/wsl/basic-commands)。
