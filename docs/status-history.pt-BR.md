# Status das coletas e importação de logs

O coletor grava uma série separada `${MEASUREMENT}_status` (padrão:
`speedtest_status`) no mesmo bucket das velocidades. O dashboard pronto para importar também exibe esses estados. Cada tentativa concluída tem `success=1i` ou `success=0i`,
`error_kind`, `error_detail` e `server_id` (campo string com o servidor solicitado,
ou `automatic`). A tag é `host`, exatamente o `HOST_TAG` da instalação.
O timestamp é o horário UTC de conclusão da tentativa, com precisão de segundos.

As novas coletas também registram `interval_seconds`, `fail_interval_seconds` e
`timeout_seconds`. Os intervalos são esperas após a execução e as tentativas de
escrita, não uma agenda de horários fixos. Esses campos não são inventados na
importação de logs antigos.

- `none`: teste bem-sucedido.
- `dns`: falha de resolução de nome.
- `network_unreachable`: rede inalcançável.
- `timeout`: processo terminou com código 124 ou 137 (limite/interrupção).
- `invalid_result`: erro ao converter o JSON do resultado.
- `speedtest_error`: outras falhas.

Sucesso do teste não significa sucesso da gravação. As escritas têm as tentativas
já configuradas em `INFLUX_RETRIES`. Se o InfluxDB também estiver inacessível, o
coletor registra a falha no log; não há fila persistente de reenvio. Guarde os logs
para poder importar depois. Ausência de status significa falta de informação,
não comprova queda da internet. Falhas não gravam velocidades zero.

## Importar o histórico

Execute no servidor que roda o Docker, com Python 3 instalado. Não é necessário
instalar Python dentro do contêiner. Use logs de **um único coletor** por execução.
O script aceita a saída com ou sem timestamps adicionais de `docker logs`.

Salve os logs em `speedtest.log`. Você pode usar o arquivo já enviado ou exportar:

```bash
docker logs --since '2026-09-24T08:30:00-03:00' --until '2026-09-24T17:30:00-03:00' ookla-speedtest-influxdb > speedtest.log 2>&1
```

No diretório do repositório, obtenha o host usado pelo contêiner:

```bash
STATUS_HOST=$(docker exec ookla-speedtest-influxdb sh -c 'printf "%s" "${HOST_TAG:-$(hostname)}"')
```

Se o host foi alterado desde o incidente, use o valor histórico. Se configurou
`MEASUREMENT` diferente de `speedtest`, passe `--measurement VALOR` em ambos os
comandos seguintes.

Primeiro confira a conversão, sem gravar no banco:

```bash
python3 scripts/import-status-logs.py speedtest.log --host "$STATUS_HOST" --output status-history.lp
```

Depois importe, aproveitando a rede e as credenciais do contêiner existente:

```bash
python3 scripts/import-status-logs.py speedtest.log --host "$STATUS_HOST" --container ookla-speedtest-influxdb --write
```

O contêiner antigo já tem curl e jq, portanto a importação funciona antes de
atualizar o coletor. Nenhum token precisa ser colado no terminal. Sem `--container`,
o modo `--write` usa INFLUX_URL, INFLUX_ORG, INFLUX_BUCKET e INFLUX_TOKEN do ambiente
local (um `.env` não é carregado automaticamente).

O trecho analisado de 24/09/2026 gera **95 pontos: 90 falhas DNS, 1 falha de rede e
4 sucessos**. Os sucessos marcam o estado anterior e a recuperação, sem reimportar
as velocidades. Use `--failures-only` se quiser importar apenas erros.

A importação usa o timestamp externo UTC do coletor, não o horário local embutido
no detalhe do erro. Repetir o mesmo arquivo com o mesmo host e measurement atualiza
os mesmos pontos, sem duplicá-los. Retenção do bucket e permissão de escrita do
token precisam permitir os horários importados. Em caso de erro HTTP, verifique a
mensagem: o servidor pode ter aceitado parte do lote; corrigir e repetir é seguro
para o mesmo arquivo. Logs antigos não permitem identificar com certeza timeouts.

## Usar no Grafana

Consulte a measurement `speedtest_status`, filtre a tag `host` e o campo `success`:
1 é sucesso, 0 é falha. `error_kind` e `error_detail` fornecem o motivo. O período
sem pontos deve aparecer como desconhecido/sem dados. Não preencha velocidade com
zero e não calcule disponibilidade temporal pela proporção de tentativas: a
frequência de coleta muda quando há falha.

## Aplicar o coletor

Após integrar esta alteração e publicar a imagem atualizada, no diretório do
Compose:

```bash
docker compose pull speedtest-influxdb
docker compose up -d speedtest-influxdb
```

Até a imagem ser publicada, `latest` continua sendo a versão anterior.

## Importar o dashboard atualizado

Use o arquivo existente `grafana/dashboard.json` desta branch. No Grafana,
importe o JSON atualizado e selecione a fonte InfluxDB (Flux), Bucket e Host.
O formato v2 do dashboard original foi preservado. As consultas de lacunas
requerem Flux 0.179+ (`internal/debug.null`, disponível no InfluxDB 2.7).

Configure **Max data age (seconds)**: `1200` para testes a cada 15 minutos,
ou mantenha `4500` para testes a cada hora. É um limite manual que inclui margem
para execução e retries; não é inferido dos logs históricos.

- Latest attempt mostra sucesso, falha ou dado desatualizado; sem status é desconhecido.
- Age of last successful test mostra a idade da última medição no período.
- Os quatro cartões antigos exibem apenas medições recentes e são identificados como último sucesso.
- Collection attempts mostra pontos verdes/vermelhos, sem interpolar períodos desconhecidos.
- Failed attempts — details lista até 500 falhas, incluindo o motivo.
- Os gráficos preservam os pontos individuais e interrompem a linha nas falhas
  registradas ou lacunas maiores que o limite, sem inventar velocidades zero.

A idade é calculada em relação ao fim do período selecionado, permitindo revisar
incidentes antigos. As consultas usam apenas dados dentro desse período. Para
períodos muito longos/coletas frequentes, reduza o intervalo exibido: os históricos
não agregam pontos para evitar esconder falhas curtas. Importe os logs antigos
antes de visualizar os painéis de status. Não é necessário esperar o merge.
