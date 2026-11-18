@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
echo ==========================================
echo Iniciando processo de commit e push...
echo ==========================================


echo.
echo ULTIMAS 8 TAGS DO BRANCH ATUAL:
echo ==========================================

REM Lista as últimas 3 tags (mais recentes) em uma única chamada ao git
REM Ordena de forma decrescente, pega as 3 primeiras e depois inverte para exibir em ordem crescente
set "temp_tags=%temp%\tags_%random%.txt"
git for-each-ref --sort=-v:refname --count=3 --format="%%(refname:short)|%%(subject)|%%(creatordate:short)" refs/tags > "%temp_tags%"

if not exist "%temp_tags%" (
    echo Nenhuma tag encontrada.
    goto :apos_listar_tags
)

REM Lê o arquivo em memória e exibe em ordem crescente (mais antiga -> mais recente)
set idx=0
for /f "usebackq tokens=1,2,3 delims=|" %%a in ("%temp_tags%") do (
    set "linha_!idx!=%%a - %%b (%%c)"
    set /a idx+=1
)

set /a idx-=1
for /l %%i in (!idx!,-1,0) do (
    echo !linha_%%i!
)

del "%temp_tags%" >nul 2>&1

:apos_listar_tags
echo.
echo ==========================================
echo.


REM Verifica se há alterações na working tree
git status --porcelain | findstr . >nul
if errorlevel 1 (
    echo NENHUMA ALTERACAO NA WORKING TREE.
    echo Nenhuma tag nova sera criada.	
    echo.

    for /f "delims=" %%b in ('git rev-parse --abbrev-ref HEAD') do set "branch_atual=%%b"

    REM Garante que o ref remoto do branch existe localmente
    git rev-parse --verify "origin/!branch_atual!" >nul 2>&1
    if errorlevel 1 (
        echo AVISO: origin/!branch_atual! nao existe localmente.
        echo Rode: git fetch origin
        goto :eof
    )

    REM Conta commits locais a frente do remoto
    set "commits_pendentes=0"
    for /f "delims=" %%c in ('git rev-list --count origin/!branch_atual!..HEAD 2^>nul') do set "commits_pendentes=%%c"

    if "!commits_pendentes!"=="0" (
        echo Nenhum commit pendente de envio no branch !branch_atual!.
		echo
		pause
        goto :eof
    )

    echo Commits locais ainda nao enviados ^(!commits_pendentes!^):
    git log origin/!branch_atual!..HEAD --oneline
    echo.
    set /p enviar="Enviar commits pendentes do branch !branch_atual! (S/N)? [S]: "
	if "!enviar!"=="" set enviar=S
    if /i "!enviar!"=="S" (
        git push origin !branch_atual!
        if errorlevel 1 (
            echo.
            echo ==========================================
            echo ERRO: falha no push do branch !branch_atual!.
            echo ==========================================
            pause
        )
    )
    goto :eof
)

echo.
echo ALTERACOES ENCONTRADAS:
git status
echo.

:loop_arquivos
set "arquivos="
set /p "arquivos=Quais arquivos deseja incluir ( . )? "
if not defined arquivos goto :sem_arquivos
if "!arquivos!"=="" goto :sem_arquivos
REM Rejeita entrada so com espacos
set "arq_teste=!arquivos: =!"
if "!arq_teste!"=="" goto :sem_arquivos
goto :add_arquivos

:sem_arquivos
echo.
echo Nao foram selecionados arquivos.
echo Digite "." para incluir tudo, ou informe um ou mais arquivos.
echo.
goto :loop_arquivos

:add_arquivos
echo Adicionando: !arquivos!
git add !arquivos!
if errorlevel 1 (
    echo.
    echo ==========================================
    echo ERRO: falha no git add !arquivos!
    echo ==========================================
    pause
    goto :fim
)

echo.
echo ULTIMAS 8 TAGS DO BRANCH ATUAL:
echo ==========================================

REM Lista as últimas 8 tags (mais recentes) em uma única chamada ao git
REM Ordena de forma decrescente, pega as 8 primeiras e depois inverte para exibir em ordem crescente
set "temp_tags=%temp%\tags_%random%.txt"
git for-each-ref --sort=-v:refname --count=8 --format="%%(refname:short)|%%(subject)|%%(creatordate:short)" refs/tags > "%temp_tags%"

if not exist "%temp_tags%" (
    echo Nenhuma tag encontrada.
    goto :apos_listar_tags
)

REM Lê o arquivo em memória e exibe em ordem crescente (mais antiga -> mais recente)
set idx=0
for /f "usebackq tokens=1,2,3 delims=|" %%a in ("%temp_tags%") do (
    set "linha_!idx!=%%a - %%b (%%c)"
    set /a idx+=1
)

set /a idx-=1
for /l %%i in (!idx!,-1,0) do (
    echo !linha_%%i!
)

del "%temp_tags%" >nul 2>&1

:apos_listar_tags
echo.
echo ==========================================
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

REM Remove o "v" do início
set "sem_v=%ultima_tag:~1%"

REM Separa por pontos
for /f "tokens=1,2,3 delims=." %%a in ("!sem_v!") do (
    set "major=%%a"
    set "minor=%%b"
    set "patch_full=%%c"
)

REM Verifica se o último caractere do patch é uma letra
set "ultimo_caractere=!patch_full:~-1!"
set "tem_letra=0"

REM Verifica se o último caractere está entre a e z
for %%L in (a b c d e f g h i j k l m n o p q r s t u v w x y z) do (
    if /i "!ultimo_caractere!"=="%%L" set "tem_letra=1"
)

if !tem_letra!==1 (
    REM Tem letra: mantém o mesmo número e incrementa apenas a letra
    set "patch_num=!patch_full:~0,-1!"
    set "letra=!patch_full:~-1!"

    REM Verifica se a letra é 'z'
    if /i "!letra!"=="z" (
        REM Se for 'z', vai para o próximo número com 'a'
        REM Remove zeros à esquerda para incrementar corretamente
        for /f "tokens=* delims=0" %%n in ("!patch_num!") do set "patch_clean=%%n"
        if "!patch_clean!"=="" set "patch_clean=0"

        set /a patch_clean+=1

        REM Formata patch com dois dígitos (preservando o formato original)
        set "patch_formatado=!patch_clean!"
        if !patch_clean! LSS 10 set "patch_formatado=0!patch_clean!"

        set "sugestao_tag=v%major%.%minor%.!patch_formatado!a"
    ) else (
        REM Não é 'z': mantém o número e incrementa a letra
        REM Converte letra para código ASCII e incrementa
        set "ascii=0"
        for /f "delims=" %%L in ('powershell -command "[int][char]'!letra!'"') do set "ascii=%%L"
        set /a ascii+=1
        for /f "delims=" %%C in ('powershell -command "[char]!ascii!"') do set "proxima_letra=%%C"

        REM Mantém o mesmo número, preservando o formato original
        set "patch_formatado=!patch_num!"

        set "sugestao_tag=v%major%.%minor%.!patch_formatado!!proxima_letra!"
    )
) else (
    REM Não tem letra: apenas incrementa o número
    set "patch_num=!patch_full!"

    REM Remove zeros à esquerda para incrementar corretamente
    for /f "tokens=* delims=0" %%n in ("!patch_num!") do set "patch_clean=%%n"
    if "!patch_clean!"=="" set "patch_clean=0"

    set /a patch_clean+=1

    REM Formata patch com dois dígitos
    set "patch_formatado=!patch_clean!"
    if !patch_clean! LSS 10 set "patch_formatado=0!patch_clean!"

    set "sugestao_tag=v%major%.%minor%.!patch_formatado!"
)

set "tagv=!sugestao_tag!"
goto :loop_mensagem

:pular_validacao
echo Usando tag inicial: !tagv!
echo.

:loop_mensagem
set "mensagem="
echo Tag da nova versao: !sugestao_tag!
echo Digite a mensagem do commit, ou "-" para alterar a tag:
set /p "mensagem=> "
if not defined mensagem (
    echo ERRO: Mensagem nao pode estar vazia!
    goto loop_mensagem
)
if "!mensagem!"=="-" goto :alterar_tag
REM Rejeita mensagem so com espacos
set "msg_teste=!mensagem: =!"
if "!msg_teste!"=="" (
    echo ERRO: Mensagem nao pode conter apenas espacos!
    goto loop_mensagem
)
goto :apos_mensagem

:alterar_tag
set "tagv="
echo Nova tag (%sugestao_tag%):
set /p "tagv=> "
if not defined tagv set "tagv=%sugestao_tag%"
set "sugestao_tag=!tagv!"
goto :loop_mensagem

:apos_mensagem
echo.
echo ==========================================
echo(Commit: !mensagem!
echo(Tag   : !tagv!
echo ==========================================
echo.

if not defined mensagem (
    echo ERRO: mensagem vazia. Abortando.
    pause
    goto :fim
)
if "!mensagem!"=="" (
    echo ERRO: mensagem vazia. Abortando.
    pause
    goto :fim
)

REM ---- Pre-valida a tag no remoto ANTES de commitar/taggear ----
set "tag_existe_remoto=0"
set "hash_remoto="
for /f "delims=" %%r in ('git ls-remote --tags origin "refs/tags/!tagv!" 2^>nul') do (
    set "tag_existe_remoto=1"
    for /f "tokens=1" %%h in ("%%r") do set "hash_remoto=%%h"
)

if !tag_existe_remoto!==1 (
    for /f "delims=" %%h in ('git rev-parse HEAD') do set "hash_local=%%h"
    if /i not "!hash_remoto!"=="!hash_local!" (
        echo.
        echo ==========================================
        echo ERRO: A tag !tagv! JA EXISTE no servidor
        echo       apontando para OUTRO commit:
        echo       remoto: !hash_remoto!
        echo       local : !hash_local!
        echo.
        echo Nada foi commitado. Escolha outra tag ou
        echo resolva manualmente. (Sem --force, por design.)
        echo ==========================================
        pause
        goto :fim
    )
)

git commit -m "!mensagem!"
if errorlevel 1 (
    echo.
    echo ==========================================
    echo ERRO: falha no git commit!
    echo ==========================================
    pause
    goto :fim
)

REM Se a tag já existe localmente (e no remoto idêntica), não recria
git rev-parse -q --verify "refs/tags/!tagv!" >nul 2>&1
if errorlevel 1 goto :criar_tag
echo Tag !tagv! ja existe localmente. Pulando criacao.
goto :apos_criar_tag

:criar_tag
git tag !tagv!
if errorlevel 1 goto :tag_erro
echo Tag !tagv! criada localmente.
goto :apos_criar_tag

:tag_erro
echo.
echo ==========================================
echo ERRO: falha ao criar a tag local !tagv!
echo Ela pode ja existir localmente.
echo Use: git tag -d !tagv!  (se quiser recriar)
echo ==========================================
pause
goto :fim

:apos_criar_tag

:pergunta_push
echo.
set /p enviar="Enviar para o servidor (S/N)? [S]: "
if "!enviar!"=="" set enviar=S
if /i "!enviar!"=="S" goto :push
if /i "!enviar!"=="N" goto :fim_sem_push
echo Opcao invalida! Use S ou N.
goto :pergunta_push

:push
echo.
echo ENVIANDO PARA O SERVIDOR...

for /f "delims=" %%b in ('git rev-parse --abbrev-ref HEAD') do set "branch_atual=%%b"
for /f "delims=" %%h in ('git rev-parse HEAD') do set "hash_local=%%h"

echo.
echo [1/2] git push origin !branch_atual!
git push origin !branch_atual!
if errorlevel 1 (
    echo.
    echo ==========================================
    echo ERRO: Falha ao enviar o branch !branch_atual!.
    echo Veja a mensagem do git acima.
    echo ==========================================
    pause
    goto :fim
)

echo.
echo [2/2] git push origin refs/tags/!tagv!
git push origin refs/tags/!tagv!
if errorlevel 1 (
    echo.
    echo ==========================================
    echo ERRO: Falha ao enviar a tag !tagv!.
    echo A tag pode ja existir no servidor com outro
    echo conteudo. Resolva manualmente (sem --force).
    echo ==========================================
    pause
    goto :fim
)

REM ---- Verificacao pos-push: confirma que a tag chegou ----
set "tag_ok=0"
for /f "tokens=1" %%h in ('git ls-remote --tags origin "refs/tags/!tagv!"') do (
    if /i "%%h"=="!hash_local!" set "tag_ok=1"
)

if !tag_ok!==0 (
    echo.
    echo ==========================================
    echo ERRO DE VERIFICACAO: a tag !tagv! nao foi
    echo encontrada no servidor apontando para
    echo !hash_local! apos o push.
    echo ==========================================
    pause
    goto :fim
)

echo ==========================================
echo Commit/push concluido! Tag: !tagv!
echo ==========================================
goto :eof

:fim_sem_push
echo.
echo ==========================================
echo Commit e tag criados localmente. Push cancelado.
echo ==========================================
goto :eof

:fim
goto :eof