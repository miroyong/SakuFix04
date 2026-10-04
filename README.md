# SakuFix04

PowerShell scripts to diagnose and apply the Ryzen mobile CPU workaround for systems
that get stuck near 0.4 GHz after boot. The workaround communicates with the AMD SMU
through the PawnIO driver; the Saku Overclock application itself is not required.

> **Aviso:** `Enable` envia comandos ao SMU e altera o estado de clock do processador.
> Use apenas em hardware compatível e por sua conta e risco. `Disable` desfaz o
> workaround e pode fazer um processador afetado voltar a ficar limitado a 0,4 GHz.

## Requisitos

- Windows com PowerShell.
- Driver PawnIO instalado.
- Privilégios de administrador para acessar o driver e gerenciar a tarefa agendada.
- O arquivo `RyzenSMU.bin`, incluído neste repositório.

O script detecta o codinome do processador e só aplica configurações definidas na
tabela de plataformas. Para alguns codinomes, a implementação de referência não
define um workaround.

## Uso manual

Abra o PowerShell como administrador na pasta do projeto.

Consultar CPU, codinome, versão da SMU e mailbox sem enviar comandos de alteração:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Fix-0.4GHz.ps1 -Action Status
```

Aplicar o workaround:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Fix-0.4GHz.ps1 -Action Enable
```

O script pede confirmação antes de enviar o comando. Para desfazê-lo explicitamente:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Fix-0.4GHz.ps1 -Action Disable
```

O parâmetro `-ModulePath` permite indicar um `RyzenSMU.bin` ou um `ZenStates-Core.dll`
alternativo. Sem esse parâmetro, o script procura primeiro o `RyzenSMU.bin` ao lado
dele e, em seguida, tenta localizar o módulo na instalação do Saku Overclock.

## Aplicar automaticamente na inicialização

Registre a tarefa agendada como administrador:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-Fix04Startup.ps1 -Install
```

A tarefa `SakuFix04-0.4GHz` executa `Apply-Fix04-AtBoot.ps1` na inicialização como
`SYSTEM`, com privilégios elevados. Ela espera pelo hardware e então aplica o
workaround incondicionalmente a cada inicialização.

Verificar o estado da tarefa e consultar as últimas linhas do log:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-Fix04Startup.ps1 -Status
```

O log fica em `C:\ProgramData\SakuFix04\fix04.log`. Para executar a tarefa também
imediatamente ao registrá-la, acrescente `-RunNow` ao comando de instalação.

Se a conta `SYSTEM` não conseguir abrir o dispositivo PawnIO, registre uma tarefa
executada no logon do usuário atual:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-Fix04Startup.ps1 -Install -AsUser
```

Remover a tarefa agendada:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-Fix04Startup.ps1 -Uninstall
```

## Origem do módulo

`RyzenSMU.bin` é o módulo PawnIO do projeto
[ZenStates-Core](https://github.com/irusanov/ZenStates-Core), distribuído aqui com a
licença GPL-3.0 incluída em [`LICENSE`](./LICENSE). O arquivo corresponde à versão
do repositório upstream no commit
[`bcd76fa`](https://github.com/irusanov/ZenStates-Core/tree/bcd76fa6f03ea4fde8dd5f3e0e8b98944567a076).
