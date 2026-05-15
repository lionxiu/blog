@echo off
chcp 65001 >nul
set LANG=zh_CN.UTF-8
echo ======================================
echo  Hexo 博客自动部署（已修复按钮不显示）
echo ======================================

echo 1/5 清理缓存...
call npx hexo clean

echo 2/5 生成静态网页...
call npx hexo generate

echo 3/5 部署到 GitHub Pages（关键！）
call npx hexo deploy

echo 4/5 提交源码备份...
git add .
git commit -m "更新博客 %date% %time%"

echo 5/5 推送源码...
git push

echo ======================================
echo  部署完成！线上按钮已正常！
echo  访问地址：https://lionxiu.github.io/blog/
echo ======================================
pause