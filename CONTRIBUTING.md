# Contribuindo

O projeto nasceu para reaproveitar um iPad mini antigo. Relatos de campo, correções de documentação e testes em outros aparelhos ajudam a transformar candidatos em aparelhos verificados.

## Teste em um aparelho

1. Abra uma issue pelo modelo de compatibilidade. Inclua o modelo exato, iOS, jailbreak e arquitetura.
2. Teste o `.deb` e o `.ipa`, consultas UDP e TCP, bloqueio ligado e desligado, Wi-Fi com a tela bloqueada, reconexão e reinício.
3. Informe a versão ou commit testado e o tempo que a tela ficou bloqueada. Remova credenciais, IP público e identificadores do aparelho dos logs.

## Envie mudanças

- Abra uma issue antes de começar mudanças grandes, especialmente para iOS 11 ou posterior, jailbreaks rootless ou outras interfaces.
- Faça um fork, crie uma branch, rode `make test` e envie um pull request. Descreva o comportamento afetado e os aparelhos usados nos testes.
- Mantenha iOS 8 e ARMv7 como alvos de referência ao alterar a interface ou o serviço. Registre a versão real do iOS e as ferramentas usadas ao validar um novo build.
- Use arquivos de lista com origem e licença verificáveis se propuser incluir uma lista externa.

## Código

| Caminho | Papel |
|---|---|
| `src/dnsblock.c` | Serviço DNS, filtro, encaminhamento e controle local |
| `app/` | Painel UIKit |
| `config/` | Lista inicial e resolvedor padrão |
| `packaging/` | Metadados Debian e configuração de `launchd` |
| `scripts/build-ios.sh` | Compilação e empacotamento para iOS |
| `tests/` | Testes de integração do serviço com resolvedor simulado |

Contribuições são aceitas sob a [licença MIT](LICENSE).
