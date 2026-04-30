call node -v
if %errorlevel% neq 0 (
    echo 错误：没有安装 Node.js
    pause
    exit
)

@echo off
echo ======================================
echo  🚀 开始自动部署博客...
echo ======================================

echo 1/5 清理缓存...
call npx hexo clean

echo 2/5 生成静态文件...
call npx hexo g

echo 3/5 提交到 Git...
git add .
git commit -m "自动部署：%date:~0,4%%date:~5,2%%date:~8,2% %time:~0,2%%time:~3,2%%time:~6,2%"

echo 4/5 推送到 GitHub...
git push

echo ======================================
echo  ✅ 部署完成！等待 3-5 分钟后访问：
echo  https://lionxiu.github.io/blog/
echo ======================================
pause
