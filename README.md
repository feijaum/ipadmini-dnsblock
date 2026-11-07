# DNSBlock Legacy

Reaproveite um iPad ou iPhone antigo como bloqueador de anúncios e rastreadores por DNS na rede de casa. O projeto começou com o iPad mini de primeira geração. A proposta é dar uma função útil a aparelhos que perderam suporte a apps modernos e facilitar a adaptação pela comunidade.

**Status da v0.1.0.** O serviço DNS passou pelos testes em Linux. Os pacotes ARMv7 foram compilados e verificados com iOS 8.0 como mínimo. A instalação no aparelho e o funcionamento com a tela bloqueada ainda precisam ser testados.

## Download da prévia

Baixe o [serviço DNS (.deb)](https://github.com/feijaum/ipadmini-dnsblock/releases/download/v0.1.0-ios.1/dnsblock-servico-0.1.0.deb) e o [painel (.ipa)](https://github.com/feijaum/ipadmini-dnsblock/releases/download/v0.1.0-ios.1/dnsblock-painel-0.1.0.ipa) na [prévia ARMv7 do GitHub](https://github.com/feijaum/ipadmini-dnsblock/releases/tag/v0.1.0-ios.1). Use o jailbreak ativo para instalar o serviço e um instalador de IPA compatível com AppSync Unified para instalar o painel. No primeiro teste, configure somente um cliente para usar o DNS do iPad.

## Como funciona

- **Serviço `.deb`** — o `launchd` mantém o serviço rodando no iOS com jailbreak. Ele atende consultas DNS por UDP e TCP na porta 53 do IPv4 da interface Wi-Fi e restringe os clientes à mesma sub-rede.
- **Painel `.ipa`** — app em Objective-C e UIKit que mostra o endereço do iPad, o estado do filtro e os contadores de consultas. O botão de bloqueio altera o filtro sem desligar o DNS.
- **Filtro local** — compara o domínio e seus sufixos com a lista. Um domínio bloqueado recebe `NXDOMAIN`. As demais consultas seguem para o resolvedor configurado. A lista inicial é pequena e editável.
- **Privacidade** — o serviço guarda apenas os totais em memória e a preferência do filtro em disco. Consultas encaminhadas são visíveis ao resolvedor DNS configurado e viajam em DNS convencional. O painel usa uma porta de controle acessível apenas no próprio iPad.

O filtro funciona nos clientes que usam esse DNS. DNS privado, DoH ou configurações próprias de alguns apps podem contorná-lo. Anúncios servidos pelo mesmo domínio do conteúdo, como os de vídeo no YouTube, ficam fora do alcance confiável desse tipo de filtro. Nesta versão, os clientes usam IPv4 para chegar ao serviço, que pode encaminhar consultas AAAA normalmente. O serviço usa um resolvedor remoto e não inclui cache próprio ou DHCP.

## Compatibilidade

| Aparelho | Sistema | Arquitetura | Situação |
|---|---|---|---|
| iPad mini (1ª geração) | iOS 8 e 9 | ARMv7 | Alvo inicial, teste físico pendente |
| Outros iPads e iPhones de 32 bits | iOS 8 a 10 | ARMv7 | Candidatos a teste |
| iPads e iPhones de 64 bits antigos | iOS 8 a 10 | ARM64 | Build opcional, sem validação física |

O serviço requer jailbreak ativo com layout tradicional de arquivos. O painel requer AppSync Unified ou um método de instalação compatível com a assinatura do pacote. Em jailbreaks como o Phoenix, reative o jailbreak depois de reiniciar o aparelho. Consulte [CONTRIBUTING.md](CONTRIBUTING.md) para registrar testes por aparelho, iOS e jailbreak.

## Compilação

O serviço e seus testes podem ser executados em Linux, com compilador C, Make e Python 3:

```sh
make test
```

Para gerar os pacotes, use um Mac com Xcode/SDK legado que compile para ARMv7 e aceite iOS 8 como versão mínima. A referência inicial é o [Xcode 7.3.1, com SDK do iOS 9.3](https://developer.apple.com/library/archive/documentation/Xcode/Conceptual/RN-Xcode-Archive/Chapters/xc7_release_notes.html). Instale também `ldid`, `zip` e `dpkg-deb` com suporte a `--root-owner-group`.

```sh
DEVELOPER_DIR=/Applications/Xcode-7.3.1.app/Contents/Developer make ios
```

O script gera `dist/dnsblock-servico-0.1.0.deb` e `dist/dnsblock-painel-0.1.0.ipa`. O nome do Xcode no comando deve corresponder ao seu. Para gerar uma compilação universal experimental, use `IOS_ARCHS="armv7 arm64" make ios` com o ambiente do Xcode legado já selecionado. É possível informar os caminhos de compilador, SDK e assinador com `IOS_CLANG`, `IOS_SDK` e `LDID`.

## Instalação e primeiro teste

1. Com o jailbreak ativo, transfira o `.deb` e instale pelo gerenciador de pacotes ou, como root, com `dpkg -i dnsblock-servico-0.1.0.deb`.
2. Instale o `.ipa` pelo seu instalador compatível com AppSync Unified. Abra **DNSBlock** e confira o IP do iPad e o estado **Conectado**.
3. No computador conectado à mesma rede, substitua `IP_DO_IPAD` e verifique uma resolução permitida, um domínio bloqueado e uma consulta por TCP:

   ```sh
   nslookup example.org IP_DO_IPAD
   nslookup doubleclick.net IP_DO_IPAD
   dig +tcp @IP_DO_IPAD example.org
   ```

   Com o filtro ligado, a consulta de `doubleclick.net` deve retornar `NXDOMAIN`.
4. Deixe o iPad no carregador, bloqueie a tela e repita os testes depois de alguns minutos e de algumas horas. Teste também reconectar ao Wi-Fi e reativar o jailbreak após reiniciar.
5. Para usar na rede inteira, reserve o IP do iPad no roteador e configure a opção de **DNS da LAN/DHCP** para anunciá-lo aos clientes. Se o iPad for o único resolvedor anunciado e ficar offline, a resolução de nomes pode parar. Para desfazer, restaure o DNS anterior no roteador ou no cliente.

### Ajustar o filtro

- Edite `/etc/ipadmini-dnsblock/blocklist.txt` com um domínio por linha. Um domínio inclui seus subdomínios. Aceita comentários com `#`.
- O arquivo `/etc/ipadmini-dnsblock/upstream` recebe um IPv4 na primeira linha. O padrão é `9.9.9.9`. Escolha um servidor alcançável pelo iPad na porta 53 que não encaminhe de volta para ele.
- Como root, reinicie o serviço após alterar os arquivos:

  ```sh
  launchctl unload /Library/LaunchDaemons/com.feijaum.ipadminidnsblock.plist
  launchctl load /Library/LaunchDaemons/com.feijaum.ipadminidnsblock.plist
  ```

Mantenha a porta 53 acessível somente na rede doméstica. Consulte [SECURITY.md](SECURITY.md) para os limites do serviço e o canal de reporte.

## Contribua e apoie

Teste um aparelho antigo, compartilhe o resultado ou envie uma adaptação. O [guia de contribuição](CONTRIBUTING.md) traz a matriz de testes e a estrutura do projeto.

O código usa a [licença MIT](LICENSE). A proposta para financiar a manutenção inclui patrocínios voluntários, suporte de configuração e builds preparadas para aparelhos testados. A cobrança ainda não foi ativada.
