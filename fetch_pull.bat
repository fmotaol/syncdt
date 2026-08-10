@echo off
setlocal enabledelayedexpansion
echo ==========================================
echo Iniciando processo de fetch e pull...
echo ==========================================

git fetch --all
git pull

echo ==========================================
echo Fetch/Pull concluido!
pause
goto :eof