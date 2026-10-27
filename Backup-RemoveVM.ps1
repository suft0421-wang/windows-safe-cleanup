param([string]$ConfigPath=(Join-Path $PSScriptRoot 'config\vm.example.json'),[switch]$Apply,[switch]$Preview,[switch]$NoPause,[switch]$LibraryOnly)
$ErrorActionPreference='Stop'
function Get-FullPath([string]$Path){[IO.Path]::GetFullPath($Path).TrimEnd('\')}
function Write-JsonFile($Value,[string]$Path){$Value|ConvertTo-Json -Depth 9|Set-Content -LiteralPath $Path -Encoding utf8}
function Get-FreeBytes([string]$Path){[IO.DriveInfo]::new([IO.Path]::GetPathRoot($Path)).AvailableFreeSpace}
function Assert-NoLink([string]$Path){
 $item=Get-Item -LiteralPath $Path -Force
 while($null -ne $item){
  if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "发现链接，保留原件：$Path"}
  if($item -is [IO.FileInfo]){$item=$item.Directory}else{$item=$item.Parent}
 }
}
function Get-SafeTree([string]$Root){
 Assert-NoLink $Root
 $queue=[Collections.Generic.Queue[string]]::new();$queue.Enqueue($Root)
 $files=[Collections.Generic.List[string]]::new();$dirs=[Collections.Generic.List[string]]::new();$dirs.Add($Root)
 while($queue.Count -gt 0){
  $current=$queue.Dequeue()
  foreach($item in Get-ChildItem -LiteralPath $current -Force){
   if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "目录包含链接，原件保留：$($item.FullName)"}
   if(!(Get-FullPath $item.FullName).StartsWith((Get-FullPath $Root)+'\',[StringComparison]::OrdinalIgnoreCase)){throw '目录边界检查失败'}
   if($item.PSIsContainer){$dirs.Add($item.FullName);$queue.Enqueue($item.FullName)}else{$files.Add($item.FullName)}
  }
 }
 [pscustomobject]@{Files=@($files);Directories=@($dirs)}
}
function Assert-SourceScope($Group,[string]$Path){
 $full=Get-FullPath $Path;$root=Get-FullPath $Group.Root
 if($full.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){return}
 if(@($Group.ExtraPaths|Where-Object{[string]::Equals((Get-FullPath $_),$full,[StringComparison]::OrdinalIgnoreCase)}).Count -eq 1){return}
 throw "目标不在指定虚拟机范围内：$full"
}
function Assert-DedicatedVmRoot([string]$Root){
 if(![IO.Path]::IsPathRooted($Root) -or $Root.StartsWith('\\')){throw 'Only explicit local absolute VM paths are supported'}
 $full=Get-FullPath $Root
 if($full -eq (Get-FullPath ([IO.Path]::GetPathRoot($Root)))){throw 'A drive root cannot be a VM folder'}
 $protected=@($env:USERPROFILE,$env:PUBLIC,$env:APPDATA,$env:LOCALAPPDATA,$env:ProgramData,$env:SystemRoot,$env:ProgramFiles)
 foreach($folder in @('Desktop','MyDocuments','ApplicationData','LocalApplicationData','CommonApplicationData')){$protected+=[Environment]::GetFolderPath($folder)}
 if($env:USERPROFILE){$protected+=Join-Path $env:USERPROFILE 'Downloads'}
 foreach($path in $protected){if($path -and $full -eq (Get-FullPath $path)){throw 'System and personal folders cannot be VM roots'}}
}
function Find-SevenZip([string]$Preferred){
 $paths=@($Preferred)
 foreach($name in @('7za.exe','7z.exe')){$command=Get-Command $name -ErrorAction SilentlyContinue;if($command){$paths+=$command.Source}}
 if($env:ProgramFiles){$paths+=Join-Path $env:ProgramFiles '7-Zip\7z.exe'}
 foreach($path in $paths){if($path -and (Test-Path -LiteralPath $path -PathType Leaf)){return (Get-Item -LiteralPath $path).FullName}}
 throw 'Install 7-Zip or configure SevenZipPath first.'
}
function New-VMGroup([string]$Id,[string]$Root,[string]$Descriptor,[string]$Config){
 Assert-DedicatedVmRoot $Root
 if($Id -notmatch '^[A-Za-z0-9_-]+$'){throw 'VM ID must contain letters, numbers, underscores or hyphens'}
 if((Get-FullPath ([IO.Path]::GetDirectoryName($Config))) -ne (Get-FullPath $Root)){throw 'Config must be inside the dedicated VM folder'}
 $tree=Get-SafeTree $Root;$descriptorText=Get-Content -LiteralPath $Descriptor -Raw
 if($descriptorText -notmatch '(?m)^parentCID=ffffffff\s*$'){throw "$Id 存在父磁盘依赖，原件保留"}
 $expected=[IO.Path]::GetFileNameWithoutExtension($Descriptor)
 $extents=@([regex]::Matches($descriptorText,'(?m)^RW\s+\d+\s+SPARSE\s+"([^"\r\n]+)"')|ForEach-Object{$_.Groups[1].Value})
 if($extents.Count -eq 0){throw "$Id 未找到磁盘分片"}
 $extra=[Collections.Generic.List[string]]::new();$all=@{}
 foreach($path in $tree.Files){$all[(Get-FullPath $path)]=$true}
 foreach($leaf in $extents){
  if($leaf -notmatch ('^'+[regex]::Escape($expected)+'-s\d{3}\.vmdk$')){throw "未预期的分片：$leaf"}
  $disk=Join-Path ([IO.Path]::GetDirectoryName($Descriptor)) $leaf;Assert-NoLink $disk;$all[(Get-FullPath $disk)]=$true
  if(!(Get-FullPath $disk).StartsWith((Get-FullPath $Root)+'\',[StringComparison]::OrdinalIgnoreCase)){$extra.Add($disk)}
 }
 $all[(Get-FullPath $Descriptor)]=$true
 if(!(Get-FullPath $Descriptor).StartsWith((Get-FullPath $Root)+'\',[StringComparison]::OrdinalIgnoreCase)){$extra.Add($Descriptor)}
 $match=[regex]::Match((Get-Content -LiteralPath $Config -Raw),'(?m)^scsi0:0\.fileName\s*=\s*"([^"]+)"')
 if(!$match.Success){throw "$Id 未识别到主磁盘配置"}
 $configured=$match.Groups[1].Value;if(![IO.Path]::IsPathRooted($configured)){$configured=Join-Path $Root $configured}
 if(![string]::Equals((Get-FullPath $configured),(Get-FullPath $Descriptor),[StringComparison]::OrdinalIgnoreCase)){throw "$Id 磁盘配置已改变，原件保留"}
 [pscustomobject]@{Id=$Id;Root=$Root;DriveRoot=[IO.Path]::GetPathRoot($Root);Files=@($all.Keys|Sort-Object);Directories=$tree.Directories;ExtraPaths=@($extra);Config=$Config}
}
function New-UbuntuGroup{
 $root=$script:taskWslRoot
 Assert-DedicatedVmRoot $root
 if(!(Test-Path -LiteralPath (Join-Path $root 'ext4.vhdx'))){throw '未找到预期的 Ubuntu 虚拟磁盘，原件保留'}
 $tree=Get-SafeTree $root
 [pscustomobject]@{Id='Ubuntu';Root=$root;DriveRoot='C:\';Files=$tree.Files;Directories=$tree.Directories;ExtraPaths=@();Config=$null}
}
function Get-FileSHA([IO.FileStream]$Stream){
 $sha=[Security.Cryptography.SHA256]::Create()
 try{$Stream.Position=0;$digest=$sha.ComputeHash($Stream);$Stream.Position=0;([BitConverter]::ToString($digest)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
function ConvertTo-NativeCommandLine([string[]]$Arguments){
 $quoted=@(foreach($argument in $Arguments){
  if($argument.Contains('"') -or $argument.Contains("`r") -or $argument.Contains("`n")){throw '参数出现未预期的引号或换行'}
  if($argument.Length -eq 0 -or $argument -match '\s'){
   '"'+[regex]::Replace($argument,'(\\+)$','$1$1')+'"'
  }else{$argument}
 })
 $quoted -join ' '
}
function Convert-ToolOutput([byte[]]$Bytes,[bool]$PreferUnicode=$false){
 if(!$Bytes -or $Bytes.Length -eq 0){return ''}
 if($Bytes.Length -ge 2 -and $Bytes[0] -eq 255 -and $Bytes[1] -eq 254){return [Text.Encoding]::Unicode.GetString($Bytes,2,$Bytes.Length-2)}
 if($Bytes.Length -ge 2 -and $Bytes[0] -eq 254 -and $Bytes[1] -eq 255){return [Text.Encoding]::BigEndianUnicode.GetString($Bytes,2,$Bytes.Length-2)}
 if($Bytes.Length -ge 3 -and $Bytes[0] -eq 239 -and $Bytes[1] -eq 187 -and $Bytes[2] -eq 191){return [Text.Encoding]::UTF8.GetString($Bytes,3,$Bytes.Length-3)}
 $sample=[Math]::Min($Bytes.Length,512);$oddZeros=0
 for($i=1;$i -lt $sample;$i+=2){if($Bytes[$i] -eq 0){$oddZeros++}}
 if($Bytes.Length % 2 -eq 0 -and $oddZeros -gt [Math]::Max(0,[int]($sample/10))){return [Text.Encoding]::Unicode.GetString($Bytes)}
 try{return [Text.UTF8Encoding]::new($false,$true).GetString($Bytes)}catch{
  if($PreferUnicode -and $Bytes.Length % 2 -eq 0){return [Text.Encoding]::Unicode.GetString($Bytes)}
  return [Text.Encoding]::Default.GetString($Bytes)
 }
}
function Invoke-LoggedTool([string]$Exe,[string[]]$ToolArgs,[string]$WorkingDirectory,[string]$LogPrefix,[string]$Label,[string]$SpacePath='', [bool]$UnicodeOutput=$false){
 $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$Exe;$start.Arguments=ConvertTo-NativeCommandLine $ToolArgs
 $start.WorkingDirectory=$WorkingDirectory;$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
 $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 [IO.File]::WriteAllText($LogPrefix+'.command.txt',$Exe+' '+$start.Arguments,[Text.UTF8Encoding]::new($false))
 $process=[Diagnostics.Process]::new();$process.StartInfo=$start;$cancelled=$false
 $outMemory=[IO.MemoryStream]::new();$errMemory=[IO.MemoryStream]::new()
 try{
  if(!$process.Start()){throw '无法启动处理工具'}
  $stdout=$process.StandardOutput.BaseStream.CopyToAsync($outMemory);$stderr=$process.StandardError.BaseStream.CopyToAsync($errMemory);$timer=[Diagnostics.Stopwatch]::StartNew()
  while(!$process.WaitForExit(1000)){
   Write-Progress -Activity $Label -Status ('已运行 {0:N0} 秒，请保持窗口开启' -f $timer.Elapsed.TotalSeconds)
   if($SpacePath -and (Get-FreeBytes $SpacePath) -lt 1GB){$process.Kill();$cancelled=$true;break}
   if($UnicodeOutput -and $timer.Elapsed.TotalSeconds -gt 180){$process.Kill();$cancelled=$true;break}
  }
  $process.WaitForExit();$stdout.GetAwaiter().GetResult();$stderr.GetAwaiter().GetResult()
  $outText=Convert-ToolOutput $outMemory.ToArray() $UnicodeOutput;$errText=Convert-ToolOutput $errMemory.ToArray() $UnicodeOutput;$exitCode=$process.ExitCode
  [IO.File]::WriteAllText($LogPrefix+'.log',$outText,[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($LogPrefix+'.error.log',$errText,[Text.UTF8Encoding]::new($false))
  if($cancelled){throw '空间不足或系统操作超时；没有删除未完成备份的原件'}
  [pscustomobject]@{ExitCode=$exitCode;Output=$outText;Error=$errText}
 }finally{Write-Progress -Activity $Label -Completed;$process.Dispose();$outMemory.Dispose();$errMemory.Dispose()}
}
function Test-ArchiveContents([string]$SevenZip,[string]$Archive,$Records,[string]$LogPrefix){
 $test=Invoke-LoggedTool $SevenZip @('t','-sccUTF-8','-bd','-y',$Archive) ([IO.Path]::GetDirectoryName($Archive)) ($LogPrefix+'-test') '校验完整压缩备份'
 if($test.ExitCode -ne 0){throw "备份校验失败，原件保留。详情：$LogPrefix-test.log"}
 $listing=Invoke-LoggedTool $SevenZip @('l','-slt','-ba','-sccUTF-8',$Archive) ([IO.Path]::GetDirectoryName($Archive)) ($LogPrefix+'-listing') '核对备份文件清单'
 if($listing.ExitCode -ne 0){throw '无法读取备份清单，原件保留'}
 $sizes=@{}
 foreach($block in [regex]::Matches($listing.Output,'(?ms)^Path = ([^\r\n]+)\r?\n(.*?)(?=^Path = |\z)')){
  $size=[regex]::Match($block.Groups[2].Value,'(?m)^Size = (\d+)\s*$')
  if($size.Success){$sizes[$block.Groups[1].Value.Replace('/','\')]=[long]$size.Groups[1].Value}
 }
 foreach($record in $Records){if(!$sizes.ContainsKey($record.RelativePath) -or $sizes[$record.RelativePath] -ne $record.Bytes){throw "备份缺少文件或大小不符：$($record.RelativePath)；原件保留"}}
}
function New-VerifiedArchive($Group,[string]$Archive,[string]$MetadataDirectory,[string]$SevenZip,[ValidateRange(1,9)][int]$CompressionLevel=1){
 if(Test-Path -LiteralPath $Archive){throw "备份目标已存在，停止以免覆盖：$Archive"}
 $handles=[Collections.Generic.List[IO.FileStream]]::new();$records=[Collections.Generic.List[object]]::new();$verified=$false;$prefix=Join-Path $MetadataDirectory $Group.Id
 try{
  $count=0
  foreach($path in $Group.Files){
   Assert-SourceScope $Group $path;Assert-NoLink $path
   $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$handles.Add($stream);$info=Get-Item -LiteralPath $path -Force
   $count++;Write-Progress -Activity ('核对 '+$Group.Id+' 的原文件') -Status "$count / $($Group.Files.Count)"
   $hash=Get-FileSHA $stream
   $records.Add([pscustomobject]@{Path=$info.FullName;RelativePath=$info.FullName.Substring($Group.DriveRoot.Length);Bytes=$stream.Length;LastWriteUtc=$info.LastWriteTimeUtc.ToString('o');SHA256=$hash})
  }
  Write-Progress -Activity ('核对 '+$Group.Id+' 的原文件') -Completed;Write-JsonFile @($records) ($prefix+'-source-files.json')
  $listPath=$prefix+'-archive-input.txt';[IO.File]::WriteAllLines($listPath,[string[]]@($records|ForEach-Object RelativePath),[Text.UTF8Encoding]::new($false))
  $create=Invoke-LoggedTool $SevenZip @('a','-t7z',('-mx='+$CompressionLevel),'-m0=LZMA2','-mmt=2','-md=32m','-ms=on','-spd','-scsUTF-8','-sccUTF-8','-bb0','-bd','-y',$Archive,('@'+$listPath)) $Group.DriveRoot ($prefix+'-create') ('压缩备份 '+$Group.Id) $Archive
  if($create.ExitCode -ne 0){throw "备份未成功，原件保留。详情：$prefix-create.log"}
  Test-ArchiveContents $SevenZip $Archive @($records) $prefix
  $archiveHash=(Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant()
  $backup=[pscustomobject]@{Id=$Group.Id;Status='Verified';Archive=$Archive;ArchiveBytes=(Get-Item -LiteralPath $Archive).Length;ArchiveSHA256=$archiveHash;SourceBytes=($records|Measure-Object Bytes -Sum).Sum;Files=@($records);RemovedFiles=0;FinalArchive=$null}
  Write-JsonFile $backup ($prefix+'-verified-backup.json');$verified=$true;$backup
 }finally{
  foreach($handle in $handles){$handle.Dispose()}
  if(!$verified -and (Test-Path -LiteralPath $Archive)){
   $parent=Get-FullPath ([IO.Path]::GetDirectoryName($Archive))
   if($parent -eq (Get-FullPath $script:taskStage) -or $parent -eq (Get-FullPath $script:taskBackupRoot)){Remove-Item -LiteralPath $Archive -Force -ErrorAction SilentlyContinue}
  }
 }
}
function Assert-BackupFile($Backup){
 if($Backup.Status -ne 'Verified' -or !(Test-Path -LiteralPath $Backup.Archive -PathType Leaf)){throw '没有已验证的完整备份，不删除原件'}
 if((Get-FileHash -LiteralPath $Backup.Archive -Algorithm SHA256).Hash -ine $Backup.ArchiveSHA256){throw '备份文件发生变化，原件保留'}
}
function Assert-OriginalFile($Record,[IO.FileStream]$Stream){
 $info=Get-Item -LiteralPath $Record.Path -Force
 if($Stream.Length -ne $Record.Bytes -or $info.LastWriteTimeUtc.ToString('o') -ne $Record.LastWriteUtc){throw "原件发生变化，保留：$($Record.Path)"}
 if((Get-FileSHA $Stream) -ine $Record.SHA256){throw "原件内容发生变化，保留：$($Record.Path)"}
}
function Remove-VerifiedSources($Group,$Backup){
 Assert-BackupFile $Backup
 foreach($record in $Backup.Files){
  Assert-SourceScope $Group $record.Path;Assert-NoLink $record.Path
  $stream=[IO.File]::Open($record.Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::Read -bor [IO.FileShare]::Delete))
  try{Assert-OriginalFile $record $stream;Remove-Item -LiteralPath $record.Path -Force -ErrorAction Stop;$Backup.RemovedFiles++}finally{$stream.Dispose()}
 }
 foreach($dir in @($Group.Directories|Sort-Object Length -Descending)){
  if(!(Test-Path -LiteralPath $dir)){continue};$full=Get-FullPath $dir;$root=Get-FullPath $Group.Root
  if($full -ne $root -and !$full.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){throw '拒绝移除范围外的目录'}
  Assert-NoLink $dir;if(@(Get-ChildItem -LiteralPath $dir -Force).Count -eq 0){Remove-Item -LiteralPath $dir -Force -ErrorAction Stop}
 }
}
function Publish-Backup($Backup,[string]$FinalDirectory){
 $destination=Join-Path $FinalDirectory ([IO.Path]::GetFileName($Backup.Archive))
 if((Get-FullPath $Backup.Archive) -ne (Get-FullPath $destination)){
  if((Get-FullPath ([IO.Path]::GetDirectoryName($Backup.Archive))) -ne (Get-FullPath $script:taskStage)){throw '备份暂存目录边界检查失败'}
  if((Get-FullPath ([IO.Path]::GetDirectoryName($destination))) -ne (Get-FullPath $script:taskBackupRoot)){throw '备份保存目录边界检查失败'}
  if((Get-FreeBytes $destination) -lt ($Backup.ArchiveBytes+1GB)){throw "D盘空间不足；完整备份仍在：$($Backup.Archive)"}
  Copy-Item -LiteralPath $Backup.Archive -Destination $destination -ErrorAction Stop
  if((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ine $Backup.ArchiveSHA256){throw "复制校验未通过；原备份仍在：$($Backup.Archive)"}
  Remove-Item -LiteralPath $Backup.Archive -Force -ErrorAction Stop;$Backup.Archive=$destination
 }
 $Backup.FinalArchive=$destination
}
function Resolve-UbuntuDistribution($Group){
 $key='HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
 if(!(Test-Path -LiteralPath $key)){throw '无法识别 Ubuntu 注册信息，原件保留'}
 $matches=@(foreach($child in Get-ChildItem -LiteralPath $key){
  $properties=Get-ItemProperty -LiteralPath $child.PSPath;$base=[string]$properties.BasePath
  if($base.StartsWith('\\?\')){$base=$base.Substring(4)}
  if($base -and [string]::Equals((Get-FullPath $base),(Get-FullPath $Group.Root),[StringComparison]::OrdinalIgnoreCase)){
   [pscustomobject]@{Name=$properties.DistributionName;BasePath=$properties.BasePath;Version=$properties.Version;RegistryKey=$child.PSPath}
  }
 })
 if($matches.Count -ne 1 -or !$matches[0].Name -or $matches[0].Version -ne 2){throw 'Ubuntu 注册信息与预期不符，原件保留'}
 $matches[0]
}
function Invoke-Wsl([string[]]$WslArgs,[string]$Label){
 $script:taskWslCounter++;$prefix=Join-Path $script:taskMetadata ('wsl-'+$script:taskWslCounter)
 $result=Invoke-LoggedTool (Join-Path $env:SystemRoot 'System32\wsl.exe') $WslArgs $PSScriptRoot $prefix $Label '' $true
 if($result.ExitCode -ne 0){throw ('WSL操作失败，未继续删除：'+$result.Output+$result.Error)}
 $result.Output.Trim([char[]]@([char]0,[char]0xfeff,[char]13,[char]10,[char]32))
}
function Test-UbuntuRunning([string]$Name){
 $running=Invoke-Wsl @('--list','--running','--quiet') '检查 Ubuntu 运行状态'
 @($running -split "`r?`n"|Where-Object{$_.Trim([char[]]@([char]0,[char]32)) -ceq $Name}).Count -gt 0
}
function Update-VMwareInventory([string[]]$Configs){
 $path=Join-Path $env:APPDATA 'VMware\inventory.vmls'
 if(!(Test-Path -LiteralPath $path)){return}
 if(@(Get-Process vmware,vmplayer -ErrorAction SilentlyContinue).Count -gt 0){Write-Host 'VMware窗口已打开，未修改界面列表；磁盘备份与删除结果不受影响。' -ForegroundColor Yellow;return}
 $encoding=[Text.Encoding]::GetEncoding(936);$lines=[IO.File]::ReadAllLines($path,$encoding)
 $removeVm=@{};$removeIndex=@{};$keepIndex=@{}
 foreach($line in $lines){
  $vm=[regex]::Match($line,'^vmlist(\d+)\.config = "([^"]+)"');if($vm.Success -and $vm.Groups[2].Value -in $Configs){$removeVm[$vm.Groups[1].Value]=$true}
  $ix=[regex]::Match($line,'^index(\d+)\.id = "([^"]+)"')
  if($ix.Success){if($ix.Groups[2].Value -in $Configs){$removeIndex[$ix.Groups[1].Value]=$true}else{$keepIndex[$ix.Groups[1].Value]=$true}}
 }
 $mapping=@{};$number=0;foreach($id in @($keepIndex.Keys|Sort-Object {[int]$_})){$mapping[$id]=$number;$number++}
 $updated=[Collections.Generic.List[string]]::new()
 foreach($line in $lines){
  if($line -match '^index\.count = '){continue}
  $vm=[regex]::Match($line,'^vmlist(\d+)\.');if($vm.Success -and $removeVm.ContainsKey($vm.Groups[1].Value)){continue}
  $ix=[regex]::Match($line,'^index(\d+)\.')
  if($ix.Success){$id=$ix.Groups[1].Value;if($removeIndex.ContainsKey($id)){continue};if($mapping.ContainsKey($id)){$updated.Add(('index'+$mapping[$id]+$line.Substring($ix.Length-1)));continue}}
  $updated.Add($line)
 }
 $updated.Add('index.count = "'+$number+'"');Assert-NoLink $path;[IO.File]::WriteAllLines($path,[string[]]$updated,$encoding)
}
if($LibraryOnly){return}
if(!$Apply){$Preview=$true}
$taskSettings=Get-Content -LiteralPath $ConfigPath -Raw|ConvertFrom-Json
if(!$taskSettings.Enabled){Write-Host 'Disabled example configuration. Copy to config/vm.local.json and edit before use. No changes made.';return}
if(@($taskSettings.VMware).Count -ne 3){throw 'This reference workflow requires exactly three standalone VMware VMs and one WSL2 distribution'}
$taskWslEntries=@(Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'|ForEach-Object{Get-ItemProperty -LiteralPath $_.PSPath}|Where-Object DistributionName -eq $taskSettings.WSL.DistributionName)
if($taskWslEntries.Count -ne 1 -or $taskWslEntries[0].Version -ne 2){throw 'Configured WSL2 distribution was not uniquely found'}
$script:taskWslRoot=[string]$taskWslEntries[0].BasePath
if($script:taskWslRoot.StartsWith('\\?\')){$script:taskWslRoot=$script:taskWslRoot.Substring(4)}
$script:taskWslCounter=0;$transcriptStarted=$false
$script:taskStage=Join-Path $PSScriptRoot 'runs\vm-backup-staging';$script:taskBackupRoot=$null;$script:taskMetadata=$null
$taskReport=[pscustomobject]@{Status='NotStarted';BackupDirectory=$null;Started=(Get-Date).ToString('o');FreeCBefore=(Get-FreeBytes 'C:\');FreeDBefore=(Get-FreeBytes 'D:\');FreeCAfter=$null;FreeDAfter=$null;Completed=@();Error=$null}
try{
 $groups=@(
  foreach($entry in $taskSettings.VMware){New-VMGroup $entry.Name $entry.Root $entry.Descriptor $entry.Config}
  New-UbuntuGroup
 )
 $sevenZip=Find-SevenZip $taskSettings.SevenZipPath;if(!(Test-Path -LiteralPath $sevenZip -PathType Leaf)){throw '未找到完整备份所需的压缩工具，原件保留'}
 $plan=@(foreach($group in $groups){[pscustomobject]@{Name=$group.Id;Files=$group.Files.Count;SourceGB=[math]::Round((@($group.Files|ForEach-Object{Get-Item -LiteralPath $_})|Measure-Object Length -Sum).Sum/1GB,3);Root=$group.Root;ExternalDiskFiles=$group.ExtraPaths}})
 Write-Host '已更新：修复了WSL命令调用与乱码。' -ForegroundColor Green
 Write-Host '先完整压缩备份并校验，再删除对应的虚拟机原件。' -ForegroundColor Cyan
 Write-Host 'Windows里的文档、代码、微信文件与WPS备份不在删除范围。'
 $plan|Format-Table Name,Files,SourceGB -AutoSize|Out-Host
 Write-JsonFile $plan (Join-Path $PSScriptRoot 'vm-removal-preview.json')
 if($Preview){Write-Host '仅检查计划，没有启动/关闭虚拟机，没有备份或删除文件。' -ForegroundColor Green;return}

 if(@(Get-Process vmware-vmx,vmware,vmplayer -ErrorAction SilentlyContinue).Count -gt 0){throw '请先正常关闭VMware虚拟机和VMware窗口，再运行本文件；未强制终止任何程序'}
 $ubuntu=Resolve-UbuntuDistribution $groups[3]
 $parent=[string]$taskSettings.BackupDirectory
 if(![IO.Path]::IsPathRooted($parent)){throw 'BackupDirectory must be absolute'}
 if(Test-Path -LiteralPath $parent){Assert-NoLink $parent}else{New-Item -ItemType Directory -Path $parent|Out-Null}
 $script:taskBackupRoot=Join-Path $parent ('虚拟机完整备份-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
 New-Item -ItemType Directory -Path $script:taskBackupRoot|Out-Null
 $script:taskMetadata=Join-Path $script:taskBackupRoot 'metadata';New-Item -ItemType Directory -Path $script:taskMetadata|Out-Null
 if(Test-Path -LiteralPath $script:taskStage){Assert-NoLink $script:taskStage}else{New-Item -ItemType Directory -Path $script:taskStage|Out-Null}
 Start-Transcript -LiteralPath (Join-Path $PSScriptRoot 'vm-removal-session.log') -Append|Out-Null;$transcriptStarted=$true
 $taskReport.BackupDirectory=$script:taskBackupRoot;$taskReport.Status='BackingUp';Write-JsonFile $taskReport (Join-Path $PSScriptRoot 'vm-removal-result.json')
 Write-JsonFile $ubuntu (Join-Path $script:taskMetadata 'Ubuntu-registration.json')
 $inventory=Join-Path $env:APPDATA 'VMware\inventory.vmls'
 if(Test-Path -LiteralPath $inventory){Copy-Item -LiteralPath $inventory -Destination (Join-Path $script:taskMetadata 'VMware-inventory-original.vmls')}
 $restore=@(
  '这里保存了虚拟机的完整压缩备份，包含内部项目、数据库、配置和系统。',
  '压缩包已逐个完成完整性测试，并核对文件清单；metadata保存源文件及压缩包的SHA256。',
  '未逐一整理内部工作文件。取回内容时，先解压相应压缩包，再打开虚拟磁盘。',
  '',
  'VMware压缩包中的路径以源磁盘根目录为基准。解压回原路径后，可用VMware打开相应vmx文件。',
  'Ubuntu压缩包中的路径以原C盘根目录为基准。可将ext4.vhdx解压到安全位置后运行：',
  'wsl --import-in-place Ubuntu-restored "已解压的ext4.vhdx完整路径"',
  '原Ubuntu注册信息保存在metadata/Ubuntu-registration.json。',
  '',
  '请保留本备份目录，直到重要文件已另外保存或确认不再需要。'
 )
 $restore|Set-Content -LiteralPath (Join-Path $script:taskBackupRoot '如何找回文件.txt') -Encoding utf8
 if(Test-UbuntuRunning $ubuntu.Name){
  Invoke-Wsl @('--distribution',$ubuntu.Name,'--user','root','--exec','sync') '保存 Ubuntu 已写入的文件'|Out-Null
  Invoke-Wsl @('--terminate',$ubuntu.Name) '停止待移除的 Ubuntu 环境'|Out-Null
 }
 $groups[3]=New-UbuntuGroup
 foreach($group in $groups){
  $source=Get-FullPath $group.Root
  foreach($target in @($script:taskBackupRoot,$script:taskStage)){
   $full=Get-FullPath $target
   if($full -eq $source -or $full.StartsWith($source+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Backups must be outside every VM source folder'}
  }
 }
 foreach($group in $groups){
  Write-Host ('正在处理：'+$group.Id+'；完整压缩可能需要数十分钟或更久，请保持窗口开启。') -ForegroundColor Cyan
  $where=if((Get-FreeBytes 'D:\') -ge (Get-FreeBytes $script:taskStage)){$script:taskBackupRoot}else{$script:taskStage}
  if((Get-FreeBytes $where) -lt 2GB){throw '空间不足以开始完整备份，保留剩余原件'}
  $archive=Join-Path $where ($group.Id+'-full.7z');$backup=New-VerifiedArchive $group $archive $script:taskMetadata $sevenZip ([int]$taskSettings.CompressionLevel)
  Write-Host ($group.Id+'：完整备份与校验成功，开始移除原件。') -ForegroundColor Green
  if($group.Id -eq 'Ubuntu'){
   Assert-BackupFile $backup
   if(Test-UbuntuRunning $ubuntu.Name){throw 'Ubuntu再次运行，停止删除；完整备份已保留'}
   foreach($record in $backup.Files){
    Assert-SourceScope $group $record.Path;Assert-NoLink $record.Path
    $stream=[IO.File]::Open($record.Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{Assert-OriginalFile $record $stream}finally{$stream.Dispose()}
   }
   Invoke-Wsl @('--unregister',$ubuntu.Name) '移除已完整备份的 Ubuntu'|Out-Null
   if(Test-Path -LiteralPath (Join-Path $group.Root 'ext4.vhdx')){throw 'Ubuntu移除后虚拟磁盘仍存在；保留备份并停止，未强制删除'}
   $backup.RemovedFiles=$backup.Files.Count
  }else{Remove-VerifiedSources $group $backup}
  Publish-Backup $backup $script:taskBackupRoot;$backup.Status='RemovedWithVerifiedBackup'
  Write-JsonFile $backup (Join-Path $script:taskMetadata ($group.Id+'-completed.json'))
  $taskReport.Completed+=@([pscustomobject]@{Name=$group.Id;SourceBytes=$backup.SourceBytes;BackupBytes=$backup.ArchiveBytes;Archive=$backup.Archive;ArchiveSHA256=$backup.ArchiveSHA256})
  $taskReport.FreeCAfter=Get-FreeBytes 'C:\';$taskReport.FreeDAfter=Get-FreeBytes 'D:\';Write-JsonFile $taskReport (Join-Path $PSScriptRoot 'vm-removal-result.json')
 }
 Update-VMwareInventory @($groups[0].Config,$groups[1].Config,$groups[2].Config)
 $taskReport.Status='Complete'
 Write-Host '两组虚拟机已移除，所有内容的完整压缩备份已保留。' -ForegroundColor Green
 Write-Host ('备份位置：'+$script:taskBackupRoot)
 Write-Host ('当前可用空间：C盘 {0:N2} GB，D盘 {1:N2} GB' -f ((Get-FreeBytes 'C:\')/1GB),((Get-FreeBytes 'D:\')/1GB))
}catch{
 $taskReport.Status='Stopped';$taskReport.Error=$_.Exception.Message
 Write-Host ('已停止：'+$_.Exception.Message) -ForegroundColor Red
 Write-Host '没有继续删除未完成备份的原件；已经成功的备份仍保留。' -ForegroundColor Yellow
 ($_|Format-List * -Force|Out-String)|Set-Content -LiteralPath (Join-Path $PSScriptRoot 'vm-removal-error.txt') -Encoding utf8
}finally{
 if(!$Preview){Write-JsonFile $taskReport (Join-Path $PSScriptRoot 'vm-removal-result.json')}
 if($transcriptStarted){try{Stop-Transcript|Out-Null}catch{}}
 if(!$NoPause){try{Read-Host '按回车结束；若有红色错误，请把最后几行发给我'|Out-Null}catch{}}
}