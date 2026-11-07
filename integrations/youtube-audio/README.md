# Conversor de áudio da Central da Casa 0.4.8

Este guia é da versão 0.4.8. A versão 0.4.9 resolve o áudio no iPad. Consulte o [guia da Central](../../README.md#youtube-na-central) para a versão atual.

O iPad faz a busca pela YouTube Data API v3. Ao selecionar um resultado, envia o ID ao conversor na rede local. O yt-dlp baixa a faixa de áudio, o FFmpeg gera um MP3 e a Central o toca pelo player nativo. A conversão usa arquivos temporários, removidos após cada resposta. Use com faixas que você tem permissão para baixar e converter.

## Iniciar em um computador com Docker

1. Baixe ou clone o [repositório da Central](https://github.com/feijaum/ipadmini-dnsblock) e abra um terminal na pasta `integrations/youtube-audio`.
2. Descubra o IP local do computador. Substitua `192.168.0.10` nos exemplos por esse IP.
3. Gere um token aleatório e guarde a saída. O mesmo token vai no arquivo e na Central.

   ```sh
   docker run --rm node:22-bookworm-slim node -p "require('node:crypto').randomBytes(24).toString('hex')"
   ```

4. Crie um arquivo local chamado `central.env` com uma linha `CENTRAL_YOUTUBE_TOKEN=COLE_AQUI_O_TOKEN`. Guarde esse arquivo fora da pasta do repositório. Execute os comandos a partir de `integrations/youtube-audio`, substituindo `CAMINHO_DO_ARQUIVO` pelo caminho do seu arquivo.

   ```sh
   docker build --pull -t central-youtube-audio .
   docker run -d --name central-youtube-audio --restart unless-stopped --env-file CAMINHO_DO_ARQUIVO -p 192.168.0.10:8787:8787 central-youtube-audio
   ```

Mantenha o computador ligado e na mesma rede do iPad. Se o firewall pedir acesso, permita a porta TCP 8787 somente na rede privada. O app aceita HTTP com IPv4 privado e o token passa pela rede local. Use uma rede de confiança e mantenha a porta sem encaminhamento no roteador.

## Configurar no iPad

1. Abra **Central da Casa → Música → YouTube → Servidor**.
2. No primeiro campo, informe `http://192.168.0.10:8787`, com o IP do computador. No segundo, cole o token criado para o conversor.
3. Salve e pesquise uma música. A chave da API que você já cadastrou em **YouTube → Chave** continua sendo usada para a busca. O token do conversor fica no campo **Servidor**.

**Parar** interrompe a faixa ou cancela a espera no iPad. A próxima faixa de uma playlist é preparada após o fim da atual. O conversor lista até 50 faixas, aceita gravações de até 20 minutos e encerra a tentativa de conversão após 90 segundos. O YouTube pode restringir algumas faixas ou bloquear o extrator. Para ver os erros do conversor, execute `docker logs central-youtube-audio`.

Para atualizar o extrator, reconstrua a imagem com `docker build --pull --no-cache -t central-youtube-audio .`, execute `docker rm -f central-youtube-audio` e repita o comando de inicialização usando o mesmo token.

## Rodar direto em Linux ou Termux

Com Python 3.10+, FFmpeg (incluindo ffprobe) e Node.js 22+ no PATH, instale o extrator em um ambiente virtual e execute `server.py`. No Termux, os pacotes são `python`, `ffmpeg` e `nodejs`. Use o IP do aparelho que vai converter o áudio.

```sh
python3 -m venv ~/.central-audio
~/.central-audio/bin/python -m pip install -U 'yt-dlp[default]'
read -r -s CENTRAL_YOUTUBE_TOKEN
export CENTRAL_YOUTUBE_TOKEN
~/.central-audio/bin/python server.py --bind 192.168.0.10
```

O comando `read` espera você colar o token e pressionar Enter. Se precisar gerar um token, use `python3 -c 'import secrets; print(secrets.token_hex(24))'`. No Termux, mantenha a sessão ativa enquanto usar a Central.
