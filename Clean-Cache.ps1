param([switch]$Apply,[switch]$Preview,[switch]$NoPause,[ValidateRange(1,3650)][int]$MinimumAgeDays=7,[string]$UserProfilePath=$env:USERPROFILE,[string]$ProgramDataPath=$env:ProgramData,[string]$OutputDirectory)
$ErrorActionPreference='Stop'
$Apply=[bool]$Apply -and -not [bool]$Preview
$Preview=-not $Apply
$taskWork=$OutputDirectory
if(!$taskWork){$taskWork=Join-Path $PSScriptRoot ('runs\cache-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))}
New-Item -ItemType Directory -Path $taskWork -Force|Out-Null
$taskTranscriptStarted=$false
try {
 try {
  Start-Transcript -LiteralPath (Join-Path $taskWork 'cleanup-session.log') -Append -ErrorAction Stop | Out-Null
  $taskTranscriptStarted=$true
 } catch {
  Write-Host '无法写入运行日志，仍会在窗口中显示结果。' -ForegroundColor Yellow
 }
$taskAllowed=@(
 (Join-Path $ProgramDataPath 'NVIDIA Corporation\NVIDIA App\UpdateFramework\ota-artifacts'),
 (Join-Path $UserProfilePath 'AppData\Local\NetEase\CloudMusic\Cache'),
 (Join-Path $UserProfilePath 'AppData\Local\KOOK\packages'),
 (Join-Path $UserProfilePath 'AppData\Roaming\KOOK\Code Cache'),
 (Join-Path $UserProfilePath 'AppData\Roaming\douyin\TTNetCache'),
 (Join-Path $UserProfilePath 'AppData\Roaming\douyin\Code Cache'),
 (Join-Path $UserProfilePath 'AppData\Local\perfectworldarena-updater'),
 (Join-Path $UserProfilePath 'AppData\Local\5eclient-updater'),
 (Join-Path $UserProfilePath 'AppData\Local\interviewcoder-updater'),
 (Join-Path $UserProfilePath 'AppData\Local\CrashDumps'),
 (Join-Path $UserProfilePath 'AppData\Local\Microsoft\Edge\User Data\component_crx_cache')
)
Write-Host '检查已知缓存目录。默认只预览；指定 -Apply 才会删除。' -ForegroundColor Cyan
Write-Host '保留：文档、代码、微信文件、WPS备份及所有虚拟磁盘。'
Write-Host '正在使用的文件或没有权限删除的文件会自动跳过。'
$taskCutoff=(Get-Date).AddDays(-$MinimumAgeDays)
$taskManifest=[System.Collections.Generic.List[object]]::new()
foreach($taskRoot in $taskAllowed){
 if(!(Test-Path -LiteralPath $taskRoot -PathType Container)){continue}
 $taskResolved=[System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $taskRoot).Path).TrimEnd('\')
 if(![string]::Equals($taskResolved,$taskRoot,[StringComparison]::OrdinalIgnoreCase)){throw "Unexpected root: $taskResolved"}
 $taskRootInfo=Get-Item -LiteralPath $taskResolved -Force
 if($taskRootInfo.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Reparse root: $taskResolved"}
 $taskQueue=[System.Collections.Generic.Queue[string]]::new()
 $taskQueue.Enqueue($taskResolved)
 while($taskQueue.Count -gt 0){
  $taskDir=$taskQueue.Dequeue()
  foreach($taskItem in Get-ChildItem -LiteralPath $taskDir -Force -ErrorAction SilentlyContinue){
   if($taskItem.Attributes -band [IO.FileAttributes]::ReparsePoint){continue}
   $taskFull=[System.IO.Path]::GetFullPath($taskItem.FullName)
   if(!$taskFull.StartsWith($taskResolved+'\',[StringComparison]::OrdinalIgnoreCase)){throw "Out-of-scope path: $taskFull"}
   if($taskItem.PSIsContainer){$taskQueue.Enqueue($taskFull);continue}
   if($taskItem.LastWriteTime -ge $taskCutoff){continue}
   if($taskRoot -match '\\KOOK\\packages$' -and $taskItem.Extension -ne '.nupkg'){continue}
   if($taskRoot -match '-updater$' -and $taskItem.Extension -ne '.exe'){continue}
   if($taskRoot -match '\\CrashDumps$' -and $taskItem.Extension -notin @('.dmp','.hdmp')){continue}
   $taskManifest.Add([pscustomobject]@{Root=$taskResolved;Path=$taskFull;Bytes=$taskItem.Length;LastWriteUtc=$taskItem.LastWriteTimeUtc;Result='Planned';Error=$null})
  }
 }
}
$taskManifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath ($taskWork+'\cleanup-file-manifest.json') -Encoding utf8
$taskBefore=[System.IO.DriveInfo]::new(([IO.Path]::GetPathRoot($UserProfilePath))).AvailableFreeSpace
if($Apply){
 foreach($taskEntry in $taskManifest){
  try{
   $taskCurrent=Get-Item -LiteralPath $taskEntry.Path -Force
   if($taskCurrent.PSIsContainer -or ($taskCurrent.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'File changed type'}
   if($taskCurrent.Length -ne $taskEntry.Bytes -or $taskCurrent.LastWriteTimeUtc -ne $taskEntry.LastWriteUtc){throw 'File changed after inventory'}
   $taskParent=$taskCurrent.Directory
   while($null -ne $taskParent){
    if($taskParent.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse ancestor'}
    if([string]::Equals($taskParent.FullName.TrimEnd('\'),$taskEntry.Root,[StringComparison]::OrdinalIgnoreCase)){break}
    $taskParent=$taskParent.Parent
   }
   if($null -eq $taskParent){throw 'Outside allowed root'}
   Remove-Item -LiteralPath $taskEntry.Path -Force -ErrorAction Stop
   $taskEntry.Result='Deleted'
  }catch{$taskEntry.Result='Skipped';$taskEntry.Error=$_.Exception.Message}
 }
}
$taskAfter=[System.IO.DriveInfo]::new(([IO.Path]::GetPathRoot($UserProfilePath))).AvailableFreeSpace
$taskSummary=[pscustomobject]@{
 Applied=[bool]$Apply;PlannedFiles=$taskManifest.Count
 PlannedBytes=($taskManifest | Measure-Object Bytes -Sum).Sum
 DeletedFiles=@($taskManifest | Where-Object Result -eq 'Deleted').Count
 DeletedBytes=($taskManifest | Where-Object Result -eq 'Deleted' | Measure-Object Bytes -Sum).Sum
 SkippedFiles=@($taskManifest | Where-Object Result -eq 'Skipped').Count
 FreeBeforeBytes=$taskBefore;FreeAfterBytes=$taskAfter
 Categories=@($taskManifest | Group-Object Root | ForEach-Object {[pscustomobject]@{Root=$_.Name;DeletedBytes=($_.Group | Where-Object Result -eq 'Deleted' | Measure-Object Bytes -Sum).Sum;Skipped=@($_.Group | Where-Object Result -eq 'Skipped').Count}})
}
if($Apply){
 $taskManifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath ($taskWork+'\cleanup-file-results.json') -Encoding utf8
 $taskSummary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath ($taskWork+'\cleanup-summary.json') -Encoding utf8
}
$taskSummary | ConvertTo-Json -Depth 5

Write-Host ''
if($Apply){
 Write-Host ('已删除旧缓存：{0:N2} GB；C盘当前可用：{1:N2} GB；跳过文件：{2}' -f ($taskSummary.DeletedBytes/1GB),($taskSummary.FreeAfterBytes/1GB),$taskSummary.SkippedFiles) -ForegroundColor Green
 Write-Host '详细结果已保存在脚本所在文件夹的 cleanup-summary.json 和 cleanup-file-results.json 中。'
}else{
 Write-Host ('仅预览，未删除：可清理约 {0:N2} GB。' -f ($taskSummary.PlannedBytes/1GB))
}

} catch {
 Write-Host ''
 Write-Host '清理未完成，以下是错误信息：' -ForegroundColor Red
 Write-Host $_.Exception.Message -ForegroundColor Red
 Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor Yellow
 $taskErrorText=($_ | Format-List * -Force | Out-String)
 try {
  $taskErrorText | Set-Content -LiteralPath (Join-Path $taskWork 'cleanup-error.txt') -Encoding utf8 -ErrorAction Stop
  Write-Host '错误详情已保存为 cleanup-error.txt。'
 } catch {
  Write-Host '无法保存错误详情，请保留窗口中的文字。' -ForegroundColor Yellow
 }
} finally {
 if($taskTranscriptStarted) { try { Stop-Transcript -ErrorAction Stop | Out-Null } catch {} }
 if(!$NoPause) {
  try { Read-Host '按回车结束；若有红色报错，请保留最后几行' | Out-Null } catch {}
 }
}