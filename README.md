# DNSBlock Legacy

Reaproveite um iPad ou iPhone antigo como bloqueador de anúncios e rastreadores por DNS na rede de casa. O projeto começou com o iPad mini de primeira geração. A proposta é dar uma função útil a aparelhos que perderam suporte a apps modernos e facilitar a adaptação pela comunidade.

## Download

A **Central da Casa 0.4.22** reúne relógio, clima, agenda, carrossel e DNSBlock em **um único pacote .deb** para ARMv7.

1. Baixe o [pacote para o iPad](https://github.com/feijaum/ipadmini-dnsblock/releases/download/v0.4.22-ios.1/dnsblock-central-0.4.22.deb).
2. Com o Carbon ativo, abra o arquivo no **Filza** e toque em **Install**. O pacote atualiza o serviço DNS existente e preserva suas configurações. O ícone da Central é um relógio em fundo azul-escuro. Se ele não aparecer, confira se o Cydia tem o pacote **UIKit Tools** instalado, atualize o cache de ícones com `su mobile -c uicache` em um terminal root e faça um respring.
3. Abra **Central da Casa**. Se você instalou o painel antigo por IPA, ele continua aparecendo como **DNSBlock**. Toque em **Bloqueio** para alternar o filtro. O iPad continua resolvendo DNS com o filtro desligado. O botão **Ajustes** mostra o IP e os contadores, permite selecionar a agenda e adicionar fotos.
4. Escolha um calendário disponível no app **Calendário** do iPad. Se a conta Google estiver sincronizada com o iOS, selecione o calendário da família. Adicione as fotos pela fototeca do iPad. Para sincronizar uma pasta privada automaticamente, siga a [configuração do Google Drive](integrations/google-drive/README.md). O carrossel embaralha a pasta e tenta trocar a imagem a cada cinco segundos, com uma transição suave. O botão **Ajustar / Preencher** alterna entre a foto inteira e o preenchimento do quadro. A agenda mostra o mês e a legenda das datas ao lado.

5. Para usar o fundo animado, abra **Ajustes → Ativar clima local** e permita a localização **durante o uso**. O iPad pode usar o Wi-Fi para estimar a posição. A Central aguarda uma leitura melhor e consulta a [Open-Meteo](https://open-meteo.com/) com coordenadas arredondadas a dois decimais, em passos de cerca de 1 km. O painel exibe temperatura, sensação térmica e cobertura de nuvens estimadas pelo modelo. **Ajustes** mostra a precisão estimada pelo iPad e o horário da leitura. Enquanto o app está aberto, o clima é consultado a cada 15 minutos. Se a rede falhar, a última leitura recente é identificada na tela e o relógio continua funcionando. Você pode desligar o clima em **Ajustes**.
6. No cartão **Música**, pesquise no YouTube, veja a fila e controle a reprodução. O áudio já iniciado pode continuar com a tela bloqueada ou ao sair do painel. O indicador no topo mostra a bateria e o carregamento enquanto o painel está visível.


Se o Safari antigo não baixar o arquivo, baixe no celular ou computador e transfira pelo [WebDAV do Filza](https://www.tigisoftware.com/default/?page_id=177#). Abra o endereço exibido pelo Filza em outro aparelho no mesmo Wi-Fi, envie o pacote e desative o WebDAV depois.

O despertador continua no app **Relógio**. A Central mantém a tela ligada enquanto está em primeiro plano. Depois de 10 minutos sem tocar na tela, ela mostra o carrossel em tela cheia na orientação atual do iPad. O relógio começa na parte inferior e muda de posição a cada 30 segundos. Toque na tela para voltar ao painel. Sem fotos disponíveis, o relógio aparece sobre um fundo escuro. O serviço DNS anterior foi testado em um iPad mini 1 com Carbon. A versão integrada ainda precisa de teste físico.

## YouTube na Central

No iPad, abra **Pesquisar no YouTube**, busque pelo nome e toque no resultado. Com o player ocupado, o resultado entra na fila do iPad. O cartão mostra a faixa atual, miniaturas, tempo decorrido e duração. Arraste a barra para mudar de posição e toque em **Próxima** para pular a faixa. A Central tenta baixar diretamente do YouTube a faixa de áudio AAC para um arquivo temporário de até 32 MB no iPad e toca depois de terminar o download. A Central apaga o arquivo ao finalizar, parar ou trocar a faixa. Pausar preserva o arquivo para retomar. O cartão tem os botões **Tocar**, **Pausar** e **Parar**. O botão **Parar** também cancela a espera durante a busca e o download do áudio.

A chave da **YouTube Data API v3** em **YouTube → Chave** serve para buscar pelo nome e listar até 50 faixas de uma playlist. Para abrir uma faixa por **Link**, a chave é opcional. Use `com.feijaum.ipadminidnsblock.central` se a restrição da chave estiver configurada para apps iOS.

A reprodução usa uma sessão de visitante temporária, mostra o progresso quando o tamanho é conhecido e valida o M4A antes de abrir no player nativo. Se o link, download ou player falhar, a Central tenta outro perfil dentro do limite total de 5 minutos por faixa. Se a conexão cair após receber parte do áudio, a Central tenta retomar do último byte recebido. A abordagem foi inspirada no [resolvedor iOS do Musike](https://github.com/Ernani1234/musike/blob/41706772a4c1e774e3bf1731ca28711fa1529cf4/mobile/ios/App/App/MusikeYouTube.swift).

Esta integração é experimental. Ela depende de o YouTube fornecer um endereço direto de áudio para a faixa e ainda precisa ser testada em um iPad mini com iOS 9. Se houver erro, o cartão indica a etapa (link, armazenamento, download ou player) e mostra o código de rede ou HTTP quando disponível. HTTP 403 indica que o YouTube recusou a entrega do áudio.

## Fila da Casa pelo Wi-Fi

Com o iPad conectado à rede local, abra no celular o endereço HTTP mostrado em **Ajustes** da Central (por exemplo, `http://192.168.0.119`). Cole o link de um vídeo do YouTube e toque em **Adicionar à fila**. A página confirma o envio e mostra quantos pedidos ainda aguardam.

O serviço guarda até 30 pedidos em memória e entrega os vídeos na ordem de chegada. A lista **A seguir** mostra as faixas do iPad e os pedidos do Wi-Fi, com os títulos disponíveis e as miniaturas. As faixas já enfileiradas no iPad tocam antes dos pedidos que aguardam no serviço. Uma faixa pausada continua ocupando o player. Para receber pedidos com o iPad ocioso, mantenha a Central aberta. Os pedidos que aguardam no serviço são apagados se ele reiniciar.

A página só escuta no IPv4 da interface Wi-Fi e aceita pedidos da mesma sub-rede. Qualquer pessoa nessa rede pode adicionar músicas. O controle do DNS e a retirada de pedidos usam a porta de controle local do iPad.

## Como funciona

- **Serviço DNS** — o `launchd` mantém o serviço rodando no iOS com jailbreak. Ele atende consultas DNS por UDP e TCP na porta 53 do IPv4 da interface Wi-Fi e restringe os clientes à mesma sub-rede.
- **Painel nativo** — app em Objective-C e UIKit com relógio, agenda e fotos, além do estado do filtro, IP e contadores. O botão de bloqueio altera o filtro sem desligar o DNS.
- **Filtro local** — compara o domínio e seus sufixos com a lista. Um domínio bloqueado recebe `NXDOMAIN`. As demais consultas seguem para o resolvedor configurado. O serviço combina a lista local editável com a lista automática.
- **Privacidade** — o serviço guarda os totais em memória, a preferência do filtro e uma cópia da lista automática em disco. Consultas encaminhadas são visíveis ao resolvedor DNS configurado e viajam em DNS convencional. O painel usa uma porta de controle acessível apenas no próprio iPad.

### Compatibilidade DNS

Em **Ajustes → Ativar compatibilidade DNS**, os domínios bloqueados passam a receber `NOERROR` com endereço nulo para A e AAAA e resposta vazia para outros tipos. A lista continua ativa e essas consultas não são encaminhadas. O modo padrão usa `NXDOMAIN`. Essa opção pode ajudar se o aplicativo testar apenas o código de resposta DNS. Aplicativos que exigem conexão com o servidor de anúncios ainda podem detectar o bloqueio.

O filtro funciona nos clientes que usam esse DNS. DNS privado, DoH ou configurações próprias de alguns apps podem contorná-lo. Anúncios servidos pelo mesmo domínio do conteúdo, como os de vídeo no YouTube, ficam fora do alcance confiável desse tipo de filtro. Nesta versão, os clientes usam IPv4 para chegar ao serviço, que pode encaminhar consultas AAAA normalmente. O serviço usa um resolvedor remoto e não inclui cache próprio ou DHCP.

## Compatibilidade

| Aparelho | Sistema | Arquitetura | Situação |
|---|---|---|---|
| iPad mini (1ª geração) | iOS 8 e 9 | ARMv7 | Alvo inicial, teste físico pendente |
| Outros iPads e iPhones de 32 bits | iOS 8 a 10 | ARMv7 | Candidatos a teste |
| iPads e iPhones de 64 bits antigos | iOS 8 a 10 | ARM64 | Build opcional, sem validação física |

O serviço requer jailbreak ativo com layout tradicional de arquivos. Em jailbreaks como o Phoenix, reative o jailbreak depois de reiniciar o aparelho. Consulte [CONTRIBUTING.md](CONTRIBUTING.md) para registrar testes por aparelho, iOS e jailbreak.

## Compilação

O serviço e seus testes podem ser executados em Linux, com compilador C, Make e Python 3:

```sh
make test
```

Para gerar os pacotes, use um Mac com Xcode/SDK legado que compile para ARMv7 e aceite iOS 8 como versão mínima. A referência inicial é o [Xcode 7.3.1, com SDK do iOS 9.3](https://developer.apple.com/library/archive/documentation/Xcode/Conceptual/RN-Xcode-Archive/Chapters/xc7_release_notes.html). Instale também `ldid` e `dpkg-deb` com suporte a `--root-owner-group`.

```sh
DEVELOPER_DIR=/Applications/Xcode-7.3.1.app/Contents/Developer make ios
```

O script gera `dist/dnsblock-central-0.4.22.deb`. O nome do Xcode no comando deve corresponder ao seu. Para gerar uma compilação universal experimental, use `IOS_ARCHS="armv7 arm64" make ios` com o ambiente do Xcode legado já selecionado. É possível informar os caminhos de compilador, SDK e assinador com `IOS_CLANG`, `IOS_SDK` e `LDID`.

## Configuração da rede

### 1. Teste com um único aparelho

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

### 2. Configure a rede inteira depois do teste

1. No roteador, faça uma **reserva DHCP** para o iPad, para que ele continue recebendo o mesmo IP.
2. Na seção **LAN/DHCP**, guarde os valores anteriores e configure o DNS entregue aos clientes com o IP reservado do iPad. A opção de DNS de **WAN/Internet** pode ser separada. Se o roteador não oferecer DNS para clientes da LAN, mantenha a configuração manual por aparelho.
3. Reconecte um cliente ao Wi-Fi para renovar a configuração e verifique no painel se há novas consultas. Um resolvedor público como DNS alternativo ou um DNS IPv6 anunciado pelo roteador pode fazer parte das consultas escapar do filtro.
4. Se o iPad ficar offline e for o único DNS anunciado, a resolução de nomes pode parar. Para desfazer, restaure o DNS anterior no roteador e reconecte os clientes.

## Lista automática de anúncios

O serviço baixa a lista [HaGeZi Multi LIGHT](https://github.com/hagezi/dns-blocklists#light) por HTTPS. A primeira tentativa acontece ao iniciar o serviço, salvo se já houver uma cópia válida com menos de 24 horas. Depois, o serviço verifica a lista a cada 24 horas enquanto estiver rodando. Em caso de falha, mantém a última lista válida e tenta novamente em uma hora.

A lista automática é substituída em memória após a validação, sem reiniciar o DNS. Entradas removidas pelo mantenedor deixam de ser bloqueadas pela lista automática. A lista local continua valendo. Veja o total de domínios automáticos em **Ajustes** da Central da Casa. A atualização ocorre no serviço em segundo plano, mesmo com o painel fechado.

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
