@echo off
setlocal enabledelayedexpansion
echo ==========================================
echo Iniciando processo de commit e push...
echo ==========================================

REM Verifica se há alterações na working tree
git status --porcelain | findstr . >nul
if errorlevel 1 (
    echo NENHUMA ALTERACAO NA WORKING TREE.
    echo Verificando se ha commits locais para enviar...
    goto :push
)

echo.
echo ALTERACOES ENCONTRADAS:
git status
echo.

set /p arquivos="Quais arquivos deseja incluir ( . )? "
if "%arquivos%"=="" set arquivos=.
git add %arquivos%


echo.
echo ULTIMAS 8 TAGS DO BRANCH ATUAL:

REM Mostra as últimas 8 tags
set count=0
for /f "delims=" %%i in ('git tag --sort=v:refname') do (
    set /a count+=1
)

set start=0
set /a start=count-8
if !start! LSS 0 set start=0

set idx=0
for /f "delims=" %%i in ('git tag --sort=v:refname') do (
    if !idx! GEQ !start! (
        echo %%i
    )
    set /a idx+=1
)
echo.

REM Pega a última tag (mais recente)
set "ultima_tag="
for /f "delims=" %%i in ('git tag --sort=v:refname') do (
    set "ultima_tag=%%i"
)

if not defined ultima_tag (
    echo Nenhuma tag encontrada. Usando versao inicial v0.0.01
    set "sugestao_tag=v0.0.01"
    set "tagv=!sugestao_tag!"
    goto :pular_validacao
)

echo Ultima tag: %ultima_tag%

REM Extrai os números da versão e possível letra
for /f "tokens=1,2,3 delims=v." %%a in ("%ultima_tag%") do (
    set "major=%%a"
    set "minor=%%b"
    set "patch_full=%%c"
)

REM Verifica se tem letra no patch
set "letra="
set "patch_num="
echo !patch_full! | findstr /r "[a-z]$" >nul
if not errorlevel 1 (
    REM Tem letra: pega número e letra separadamente
    set "patch_num=!patch_full:~0,-1!"
    set "letra=!patch_full:~-1!"
    
    REM Converte letra para código ASCII e incrementa
    set "ascii=0"
    for /f "delims=" %%L in ('powershell -command "[int][char]'!letra!'"') do set "ascii=%%L"
    set /a ascii+=1
    for /f "delims=" %%C in ('powershell -command "[char]!ascii!"') do set "proxima_letra=%%C"
    
    REM Formata patch com dois dígitos e letra incrementada
    if !patch_num! LSS 10 (
        set "patch_formatado=0!patch_num!"
    ) else (
        set "patch_formatado=!patch_num!"
    )
    set "sugestao_tag=v%major%.%minor%.!patch_formatado!!proxima_letra!"
) else (
    REM Não tem letra: apenas incrementa o número
    set "patch_num=!patch_full!"
    
    REM Remove zeros à esquerda para incrementar corretamente
    for /f "tokens=* delims=0" %%n in ("!patch_num!") do set "patch_clean=%%n"
    if "!patch_clean!"=="" set "patch_clean=0"
    
    set /a patch_clean+=1
    
    REM Formata patch com dois dígitos
    if !patch_clean! LSS 10 (
        set "patch_formatado=0!patch_clean!"
    ) else (
        set "patch_formatado=!patch_clean!"
    )
    set "sugestao_tag=v%major%.%minor%.!patch_formatado!"
)

echo Sugestao: %sugestao_tag%
echo.

:loop_tag
set "tagv="
set /p tagv="Digite a tag da versao (%sugestao_tag%): "

REM Se o usuário pressionar Enter sem digitar nada, usa a sugestão
if "!tagv!"=="" (
    set "tagv=!sugestao_tag!"
    echo Usando tag sugerida: !tagv!
    echo.
)

REM PULA A VALIDAÇÃO COMPLETAMENTE
echo Tag escolhida: !tagv!
echo.
goto :loop_mensagem

:pular_validacao
echo Usando tag inicial: !tagv!
echo.

:loop_mensagem
set /p mensagem="Digite a mensagem do commit: "
if "!mensagem!"=="" (
    echo ERRO: Mensagem nao pode estar vazia!
    goto loop_mensagem
)

git commit -m "!mensagem!"
git tag !tagv!

:push
echo.
echo ENVIANDO PARA O GITHUB...
git push --all
if errorlevel 1 (
    echo.
    echo ERRO: Falha no push --all!
    pause
)

git push --tags
if errorlevel 1 (
    echo.
    echo ERRO: Falha no push --tags!
    pause
)

echo ==========================================
echo Processo concluido!
pause
goto :eof