# 发布到 GitHub

目标：新建公开仓库 windows-safe-cleanup。

只上传本项目目录的源代码、示例配置、tests、docs、.github、README、.gitignore 和 .gitattributes。不要上传上级 outputs 目录，更不要上传整个清理工作区。

本项目包已经排除：

- 私人运行报告、文件清单、错误日志和本地配置。
- 所有虚拟磁盘、内存状态、系统镜像与压缩备份。
- 账号凭据、SSH私钥和真实个人路径。

## 网页上传

1. GitHub创建新仓库，名称windows-safe-cleanup，选择Public。
2. 将项目包解压。
3. 使用仓库的上传文件功能上传项目内容；保留config、tests、docs和.github的目录结构。
4. 检查文件列表后提交。GitHub Actions会运行临时目录中的测试。

请在GitHub仓库中自行决定采用哪种开源许可证。本项目包没有替你授予第三方使用、修改或分发代码的额外许可证。

## 在新聊天里让助手继续

如果GitHub插件刚刚安装，按官方说明在新聊天中使用插件。告诉助手：

请使用GitHub插件，将本机windows-safe-cleanup项目发布为新的公开仓库windows-safe-cleanup。先检查项目中的README与文件清单，只上传项目源代码、示例配置和测试，不上传私人日志、备份或上级outputs目录。目标仓库若已存在，先核对内容，避免覆盖其他项目。

然后附上本项目文件夹或ZIP包。
