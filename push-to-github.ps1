<#
  一键把本目录上传到 GitHub。

  用法（在本目录打开 PowerShell）：
    .\push-to-github.ps1 -Repo 你的账号/sub2api-deploy

  前置：
    1. 先在 GitHub 网页上创建同名空仓库（不要勾选 README / .gitignore / LICENSE）
    2. 本机已安装 Git（git --version 能跑）
    3. 首次推送会弹出 GitHub 登录窗口，用浏览器完成即可
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Repo
)

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

if ($Repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
    throw "仓库格式应为「账号/仓库名」，例如 zhangsan/sub2api-deploy"
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "找不到 git，请先安装 Git for Windows"
}

# 1) README 里的占位地址换成真实仓库
$readmePath = Join-Path $PWD 'README.md'
$raw = [System.IO.File]::ReadAllText($readmePath, [System.Text.Encoding]::UTF8)
$new = $raw -replace '<你的账号>/sub2api-deploy', $Repo
if ($new -ne $raw) {
    [System.IO.File]::WriteAllText($readmePath, $new, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "[1/4] README 已写入仓库地址：$Repo" -ForegroundColor Green
} else {
    Write-Host "[1/4] README 已是目标仓库地址，跳过" -ForegroundColor DarkGray
}

# 2) 设置远端
$url = "https://github.com/$Repo.git"
git remote remove origin 2>$null | Out-Null
git remote add origin $url
Write-Host "[2/4] 远端：$url" -ForegroundColor Green

# 3) 提交（有变更才提交）
git add -A
$staged = git diff --cached --name-only
if ($staged) {
    $who = if ($env:USERNAME) { $env:USERNAME } else { 'sub2api-deploy' }
    git -c user.name="$who" -c user.email="$who@users.noreply.github.com" `
        commit -m "docs: 填入仓库地址 $Repo" | Out-Null
    Write-Host "[3/4] 已提交 README 变更" -ForegroundColor Green
} else {
    Write-Host "[3/4] 没有需要提交的变更" -ForegroundColor DarkGray
}

# 4) 推送
Write-Host "[4/4] 开始推送；如弹出登录窗口，用浏览器完成 GitHub 登录..." -ForegroundColor Yellow
git push -u origin main
if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "完成：https://github.com/$Repo" -ForegroundColor Green
    Write-Host "安装命令：" -ForegroundColor Cyan
    Write-Host "  curl -sSL https://raw.githubusercontent.com/$Repo/main/deploy.sh | sudo bash" -ForegroundColor Cyan
} else {
    Write-Host ""
    Write-Host "推送失败。常见原因：" -ForegroundColor Red
    Write-Host "  1. GitHub 上的仓库还没建（建空仓库，不要勾 README）"
    Write-Host "  2. 登录窗口被关闭 —— 重新运行脚本再试"
    Write-Host "  3. 本机 Git 凭据冲突 —— 打开「凭据管理器」删掉 github.com 相关项后重试"
    exit 1
}
