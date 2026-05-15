@echo off
chcp 65001 >nul
set LANG=zh_CN.UTF-8
echo ======================================
echo  🚀 Hexo 博客自动部署
echo ======================================

echo 1/3 清理缓存...
call npx hexo clean

echo 2/3 生成静态文件...
call npx hexo generate

echo 3/3 正在部署...
call npx hexo s

echo ======================================
echo  ✅ 部署完成！
echo ======================================
pause