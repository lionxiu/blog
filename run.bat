@echo off
chcp 65001 >nul
set LANG=zh_CN.UTF-8
echo ======================================
echo  🚀 Hexo 博客自动部署
echo ======================================

echo 1/6 清理缓存...
call npx hexo clean

echo 2/6 生成静态文件...
call npx hexo generate

echo 4/6 提交更新...
git add .
git commit -m "更新博客 %date% %time%"

echo 5/6 推送到 GitHub...
git push

echo.
echo ======================================
echo  ✅ 部署完成！
echo  访问地址：https://lionxiu.github.io/blog/
echo ======================================
echo.
pause