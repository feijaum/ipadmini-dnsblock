# Fotos da família no Google Drive

A Central exibe até 20 das imagens mais novas de uma pasta privada do Drive. Ela consulta a pasta ao abrir e a cada cinco minutos enquanto está aberta. A edição e o envio ficam no app Drive de cada celular. A agenda continua sendo lida do calendário que você escolheu no iPad.

## 1. Prepare a pasta

1. No Google Drive, crie uma pasta **Fotos da Família** e compartilhe com a outra pessoa como **Editora**. Mantenha o acesso geral como **Restrito**.
2. Copie o ID da pasta. Em um link que contém `/folders/ID_DA_PASTA`, é o trecho após `/folders/`, antes de um eventual `?`. Coloque uma foto JPEG na pasta para o primeiro teste.
3. Gere uma chave aleatória de pelo menos 24 caracteres num gerenciador de senhas. Use somente letras, números, hífen e sublinhado. Guarde a chave. Ela dá acesso de leitura às fotos dessa pasta pela ponte.

## 2. Publique a ponte na sua conta

1. Abra [Google Apps Script](https://script.google.com/home) no navegador com a conta que tem acesso à pasta e crie um **Novo projeto**.
2. Cole o conteúdo de [Code.gs](Code.gs) no editor.
3. Em **Configurações do projeto**, ative **Mostrar o arquivo de manifesto appsscript.json no editor**. Volte ao editor e substitua o conteúdo desse arquivo pelo [manifesto deste projeto](appsscript.json). Ele limita a autorização do Drive à leitura. O Google apresenta essa permissão para o Drive da conta, e a ponte usa apenas a pasta configurada abaixo.
4. Em **Configurações do projeto → Propriedades do script**, crie `FOLDER_ID` com o ID da pasta e `ACCESS_KEY` com a chave aleatória. Salve.
5. Em **Implantar → Nova implantação**, escolha **App da Web**. Selecione **Executar como: Eu** e o acesso **Qualquer pessoa**, inclusive sem login. Autorize na sua conta e copie a URL que termina em `/exec`.

A opção **Qualquer pessoa** permite que o iPad chegue à ponte sem login. As fotos só são retornadas quando a chave correta é enviada por HTTPS. A pasta permanece restrita. Guarde a chave separada da URL. Para revogar o acesso, troque `ACCESS_KEY` nas propriedades do script e reconecte o iPad.

## 3. Conecte o carrossel

1. Instale a Central da Casa 0.4.0 ou posterior e abra **Ajustes → Conectar fotos do Drive**.
2. Cole a URL `/exec` e a chave que salvou em `ACCESS_KEY`. Toque em **Conectar**.
3. Confira o resultado no cartão de fotos e em **Ajustes**. Para buscar agora, use **Atualizar fotos do Drive**.

O iPad recebe JPEG ou PNG. Para arquivos maiores ou em formatos como HEIC, a ponte usa a prévia do Drive quando ela está disponível. Se uma imagem não aparecer, tente enviar uma versão em JPEG. Adicione as fotos diretamente na pasta, sem subpastas. As imagens da fototeca servem de alternativa quando o carrossel não tem fotos do Drive disponíveis. Se a rede cair com a Central aberta, a última seleção do Drive continua em memória até o app ser fechado.
