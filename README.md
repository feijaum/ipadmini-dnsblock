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

## Instalação e configuração no iPad

Este passo a passo usa um iPad mini de 1ª geração com iOS 9.3.5 e jailbreak Carbon. Comece com o iPad e o aparelho que vai fazer o teste na mesma rede Wi-Fi.

### 1. Instale o que precisa no Cydia

1. Abra o **Cydia** com o Carbon ativo e deixe as fontes atualizarem. Se aparecer **Preparando sistema de arquivos** no primeiro uso, espere concluir.
2. Em **Buscar**, procure **Filza File Manager** da fonte **BigBoss**. Toque em **Instalar → Confirmar**. No iPad mini 1, use o **Filza File Manager** compatível com iOS 9 e 32 bits, identificado como `com.tigisoftware.filza`. Se a fonte BigBoss não listar uma versão compatível, consulte a fonte oficial da TIGI em **Fontes → Editar → Adicionar** com `https://tigisoftware.com/repo/`. [Instruções da TIGI](https://www.tigisoftware.com/default/?p=439)
3. Em **Instalado**, confira se **AppSync Unified** já aparece. Se aparecer, pode seguir. Se faltar, vá em **Fontes → Editar → Adicionar** e tente adicionar `https://cydia.akemi.ai/`. Procure **AppSync Unified**, de Karen/あけみ, e instale. Se a fonte falhar, baixe o [AppSync Unified oficial em `iphoneos-arm`](https://github.com/akemin-dayo/AppSync/releases/download/116.0/ai.akemi.appsyncunified_116.0_iphoneos-arm.akemi-git-235aca6cddfbdc9fa87fcb5b2aec2df37ed6d65a.deb), transfira pelo passo 2 abaixo e instale esse arquivo no Filza antes do painel. Se a instalação manual acusar falta de `mobilesubstrate`, instale **Cydia Substrate** pelo Cydia e tente de novo. [Código e documentação do AppSync](https://github.com/akemin-dayo/AppSync)
4. Se o Cydia mostrar **Reiniciar SpringBoard**, confirme. No Carbon com iOS 9.3.5, o pacote **iocaste untether** é opcional para o primeiro teste. Ele faz o jailbreak voltar automaticamente após um reinício completo. Sem ele, rode o Carbon de novo depois de reiniciar. Se decidir instalá-lo, procure **iocaste untether** no Cydia e deixe a instalação terminar antes de sair do app. [Guia do Carbon](https://ios.cfw.guide/using-carbon/#untethering-9-3-5-9-3-6)

### 2. Baixe e transfira os arquivos

1. Abra a [página da prévia ARMv7](https://github.com/feijaum/ipadmini-dnsblock/releases/tag/v0.1.0-ios.1) e baixe **dnsblock-servico-0.1.0.deb** e **dnsblock-painel-0.1.0.ipa**. Enquanto o repositório for privado, use uma conta com acesso.
2. Se o Safari do iPad oferecer **Abrir em… → Filza**, use essa opção. Se o Safari antigo falhar no login ou no download, baixe no Android ou no computador e faça a transferência pelo Wi-Fi.
3. Para transferir pelo Wi-Fi, no iPad abra **Filza → Ajustes → Enable WebDAV server**. No outro aparelho, que deve estar na mesma rede, abra no navegador o endereço HTTP exibido pelo Filza. Use **Upload** para enviar os arquivos a uma pasta que você consiga localizar. Mantenha o Filza aberto enquanto envia e desligue o servidor WebDAV depois. [Guia do Filza](https://www.tigisoftware.com/default/?page_id=177#)

### 3. Instale e abra o DNSBlock

1. No Filza, abra **dnsblock-servico-0.1.0.deb**, toque em **Install** e espere terminar. O pacote configura o serviço para iniciar pelo `launchd`.
2. Se precisar instalar o AppSync pelo arquivo manual, abra o **.deb do AppSync** no Filza antes de instalar o painel. Depois, abra **dnsblock-painel-0.1.0.ipa** e toque em **Install**.
3. Na tela inicial, abra **DNSBlock**. Confira se aparece **Conectado**, se **Bloqueio** está ligado e anote o **IP para usar como DNS**. Use o botão de atualizar no canto superior para consultar o estado e os contadores.
4. Se o painel mostrar **Serviço indisponível**, confirme que o jailbreak continua ativo, que o iPad tem um IPv4 no Wi-Fi e que a instalação do **serviço .deb** terminou com sucesso. Atualize o painel depois de reconectar à rede. Se um instalador mostrar erro, guarde a mensagem completa para diagnóstico.

### 4. Teste com um único aparelho

#### Pelo Android

Com o Android no mesmo Wi-Fi do iPad, instale o [Termux pelo F-Droid](https://f-droid.org/en/packages/com.termux/) e abra o terminal. Instale o pacote de consultas DNS:

```sh
pkg install dnsutils
```

Substitua `192.168.1.50` pelo endereço mostrado no painel do iPad:

```sh
dig +time=3 +tries=1 @192.168.1.50 example.org
dig +time=3 +tries=1 @192.168.1.50 doubleclick.net
```

O primeiro deve mostrar `status: NOERROR` e um endereço na seção `ANSWER`. Com o bloqueio ligado, o segundo deve mostrar `status: NXDOMAIN`. Os comandos consultam o iPad diretamente e não alteram o DNS do celular. Repita com a tela do iPad bloqueada para testar se ele continua respondendo.

#### Pelo computador

Primeiro, num computador na mesma rede, troque `IP_DO_IPAD` pelo endereço mostrado no painel. Os comandos consultam o iPad diretamente, sem mudar a configuração de rede do computador.

```sh
nslookup example.org IP_DO_IPAD
nslookup doubleclick.net IP_DO_IPAD
```

Com o bloqueio ligado, `example.org` deve resolver e `doubleclick.net` deve retornar **NXDOMAIN**. Atualize o painel e confirme que os contadores aumentaram. Para verificar TCP, se tiver o `dig`, use `dig +tcp @IP_DO_IPAD example.org`. Repita as consultas com o iPad carregando e com a tela bloqueada, primeiro após alguns minutos e depois após algumas horas.

Para navegar usando esse DNS no Windows, pressione **Win + R**, digite `ncpa.cpl`, abra **Propriedades** do adaptador Wi-Fi e depois **Protocolo IP Versão 4 (TCP/IPv4) → Propriedades**. Guarde a configuração anterior, selecione **Usar os seguintes endereços de servidor DNS** e informe o IP do iPad como **DNS preferencial**. Deixe o alternativo em branco durante o teste e preserve as configurações de endereço IP e gateway. Se o navegador usar DNS seguro próprio ou se houver outro resolvedor anunciado via IPv6, as consultas de navegação podem contornar o filtro. Para desfazer, restaure as configurações anteriores. [Configurações de rede do Windows](https://support.microsoft.com/en-gb/windows/experience/connectivity-networking/essential-network-settings-and-tasks-in-windows)

### 5. Configure a rede inteira depois do teste

1. No roteador, faça uma **reserva DHCP** para o iPad, para que ele continue recebendo o mesmo IP.
2. Na seção **LAN/DHCP**, guarde os valores anteriores e configure o DNS entregue aos clientes com o IP reservado do iPad. A opção de DNS de **WAN/Internet** pode ser separada. Se o roteador não oferecer DNS para clientes da LAN, mantenha a configuração manual por aparelho.
3. Reconecte um cliente ao Wi-Fi para renovar a configuração e verifique no painel se há novas consultas. Um resolvedor público como DNS alternativo ou um DNS IPv6 anunciado pelo roteador pode fazer parte das consultas escapar do filtro.
4. Se o iPad ficar offline e for o único DNS anunciado, a resolução de nomes pode parar. Para desfazer, restaure o DNS anterior no roteador e reconecte os clientes.

## Ajustes avançados do filtro

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
