# Segurança

A série 0.1.x é experimental e foi projetada para uma rede doméstica confiável. O DNS escuta no IPv4 da interface Wi-Fi e aceita clientes na mesma sub-rede. A página de pedidos de música escuta na porta HTTP 80 da mesma interface e aceita pedidos sem conta dos clientes da sub-rede. Mantenha as portas 53 e 80 sem redirecionamento no roteador.

O processo abre a porta privilegiada durante a inicialização e depois troca para o usuário `mobile`. O controle escuta em `127.0.0.1:8753` e aceita comandos de processos locais que consigam abrir essa conexão. Contadores são agregados e ficam em memória. As consultas permitidas seguem para o resolvedor configurado em DNS convencional.

Para reportar falhas exploráveis, use [o reporte privado do GitHub](https://github.com/feijaum/ipadmini-dnsblock/security/advisories/new) quando habilitado. Caso esteja indisponível, abra uma issue solicitando um canal privado, sem publicar detalhes da exploração.
