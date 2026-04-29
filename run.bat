@echo off
chcp 65001
cd /d "E:\lionxiu\bok"
echo ==============================
echo 正在启动 Hexo 博客...
echo ==============================

call node -v
if %errorlevel% neq 0 (
    echo 错误：没有安装 Node.js
    pause
    exit
)

call npx hexo clean
call npx hexo g
call npx hexo s

echo 博客已启动！
pause