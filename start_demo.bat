@echo off
echo ==========================================
echo  Smart Care - demo launcher
echo ==========================================
echo.
echo Before continuing: open XAMPP Control Panel and Start MySQL (must be green).
echo.
pause

start "Backend" cmd /k "cd /d %~dp0backend && .venv\Scripts\python.exe -m fastapi dev main.py"
timeout /t 8 /nobreak >nul

start "Bracelet Simulator" cmd /k "cd /d %~dp0backend && .venv\Scripts\python.exe simulate_bracelet.py"
timeout /t 3 /nobreak >nul

start "Flutter App" cmd /k "cd /d %~dp0app && flutter run -d chrome"
