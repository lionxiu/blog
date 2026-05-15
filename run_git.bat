@echo off
chcp 65001 >nul
set LANG=zh_CN.UTF-8

echo ======================================
echo  Hexo 博客自动部署（已修复按钮不显示）
echo ======================================

echo 1/6 清理缓存...
call npx hexo clean

echo 2/6 生成静态网页...
call npx hexo generate

echo 3/6 部署到 GitHub Pages
call npx hexo deploy

echo 4/6 提交源码备份...
git add .
git commit -m "更新博客 %date% %time%"

echo 5/6 推送源码...
git push

echo ======================================
echo  部署完成！
echo  地址：https://lionxiu.github.io/blog/
echo ======================================
pause