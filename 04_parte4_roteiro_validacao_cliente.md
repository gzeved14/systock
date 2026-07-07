# Parte 4 — Estratégia de Validação com o Cliente
## Roteiro para reunião de validação dos dados de Fevereiro/2025

---

## 1. Principais pontos a validar com o cliente

Durante a implantação, seis inconsistências concretas foram identificadas nos
dados de origem. Cada uma delas deve ser apresentada ao cliente como uma
pergunta objetiva, não como uma acusação de erro — o objetivo é confirmar se
é comportamento esperado do sistema legado ou se é falha de exportação.

### 1.1 Volume de linhas vazias nos arquivos de origem
O arquivo de vendas trazia 999 linhas, das quais apenas 33 (3,3%) continham
dados reais — as demais 966 eram linhas em branco.

**Pergunta ao cliente:** "A exportação do sistema de origem sempre gera um
range fixo de linhas (ex: exportação de uma planilha de 999 células), ou
esse volume de linhas vazias é sintoma de algum problema na extração?"

### 1.2 Formato de data inconsistente dentro do mesmo arquivo
Foram identificados dois formatos de data coexistindo na mesma origem:
americano (`MM/DD/YYYY`) e ISO (`YYYY-MM-DD`).

**Pergunta ao cliente:** "O sistema de origem exporta datas em mais de um
formato dependendo da tela/rotina utilizada? Isso pode indicar que os dados
vêm de módulos ou integrações diferentes."

### 1.3 Quantidades vendidas fracionadas em produtos aparentemente unitários
Produtos como P16 (37,11 un) e P26 (3,11 un) aparecem com quantidade vendida
fracionada, mesmo com unidade de medida "UN".

**Pergunta ao cliente:** "Esses produtos são vendidos fracionados (ex: a
granel, por peso) ou a quantidade fracionada é um erro de digitação/EAN no
PDV de origem?"

### 1.4 Campo `qtde_pendente` de pedidos de compra não reflete a realidade
Em vários pedidos (ex: produto P1: pedido de 96, recebido 10), o campo
`qtde_pendente` do sistema de origem aparece zerado, quando o cálculo real
indicaria pendência.

**Pergunta ao cliente:** "O campo de quantidade pendente é atualizado
automaticamente pelo sistema a cada recebimento, ou é um campo de
preenchimento manual/lote que pode ficar desatualizado?"

### 1.5 Pedidos duplicados sem vínculo de ordem de compra
Para vários produtos (P12 a P20), existe um segundo registro de pedido com
o mesmo produto e fornecedor, mas sem número de ordem de compra preenchido.

**Pergunta ao cliente:** "Esses pedidos sem ordem de compra são válidos
(ex: reprocessamento, ajuste manual) ou representam um erro de integração
que gerou registros órfãos?"

### 1.6 Ausência de vínculo entre produto e fornecedor
A tabela de produtos não trazia o fornecedor vinculado para nenhum dos 20
produtos carregados.

**Pergunta ao cliente:** "O vínculo produto-fornecedor é obrigatório no
cadastro do sistema de origem? Se sim, por que não veio preenchido na
exportação? Existe uma tabela de relação N:N (produto pode ter mais de um
fornecedor) que não fazia parte do escopo desta migração?"

---

## 2. Técnicas utilizadas para garantir exatidão e precisão dos dados

- **Camada de staging isolada:** todos os arquivos foram primeiro carregados
  em tabelas de staging com colunas 100% texto, sem constraints. Isso evita
  que erro de tipo ou de chave interrompa a importação, e permite auditar o
  dado bruto antes de qualquer transformação.

- **Contagem staging x final:** após cada carga, foi feita a comparação
  entre o total de linhas na staging e o total de linhas que efetivamente
  entraram na tabela final, isolando exatamente quantas e quais linhas
  foram descartadas e por quê (chave vazia, duplicidade, etc.).

- **Validação de chave antes do INSERT:** cada carga final filtra
  explicitamente linhas sem os campos que compõem a chave primária,
  evitando registros "fantasmas" na base de produção.

- **Parsing de data tolerante a formato misto:** função dedicada testa
  múltiplos formatos (ISO, MM/DD/YYYY, DD/MM/YYYY) antes de descartar uma
  data como inválida, reduzindo perda de dados por causa de inconsistência
  de formato na origem.

- **Normalização de separador decimal:** função dedicada converte o
  separador decimal brasileiro (vírgula) para o padrão aceito pelo banco
  (ponto), incluindo tratamento de possíveis separadores de milhar.

- **Cross-check entre tabelas relacionadas:** a pendência de pedidos de
  compra foi recalculada cruzando `pedido_compra` com `entradas_mercadoria`
  via `ordem_compra`, em vez de confiar apenas no campo pré-calculado da
  origem — o que revelou a divergência do item 1.4.

- **Segregação de dados incompletos:** registros sem vínculo de chave
  (ex: `ordem_compra` vazio) foram reportados separadamente, em vez de
  serem tratados como "zerados"/"sem pendência", evitando conclusões
  incorretas sobre o real status do pedido.

---

## 3. Consultas de apoio para a reunião de validação

### 3.1 Resumo de qualidade da carga (staging x final)
```sql
SELECT 'venda' AS tabela,
       (SELECT count(*) FROM staging.venda_raw) AS staging_qtd,
       (SELECT count(*) FROM systock.venda) AS final_qtd
UNION ALL
SELECT 'pedido_compra',
       (SELECT count(*) FROM staging.pedido_compra_raw),
       (SELECT count(*) FROM systock.pedido_compra)
UNION ALL
SELECT 'entradas_mercadoria',
       (SELECT count(*) FROM staging.entradas_mercadoria_raw),
       (SELECT count(*) FROM systock.entradas_mercadoria)
UNION ALL
SELECT 'produtos_filial',
       (SELECT count(*) FROM staging.produtos_filial_raw),
       (SELECT count(*) FROM systock.produtos_filial)
UNION ALL
SELECT 'fornecedor',
       (SELECT count(*) FROM staging.fornecedor_raw),
       (SELECT count(*) FROM systock.fornecedor);
```
Uso na reunião: mostra de forma transparente quantas linhas foram
descartadas em cada tabela e serve de gancho para o item 1.1.

### 3.2 Vendas de fevereiro/2025 por produto (quantidade e valor)
```sql
SELECT
    v.produto_id,
    SUM(v.qtde_vendida)                    AS qtde_total_vendida,
    SUM(v.qtde_vendida * v.valor_unitario) AS valor_total_vendido
FROM systock.venda v
WHERE v.data_emissao >= DATE '2025-02-01'
  AND v.data_emissao <  DATE '2025-03-01'
GROUP BY v.produto_id
ORDER BY v.produto_id;
```
Uso na reunião: base para o cliente conferir, produto a produto, se os
totais batem com o relatório do sistema legado. Também expõe os produtos
com quantidade fracionada (item 1.3) para confirmação direta.

### 3.3 Divergência entre `qtde_pendente` de origem e pendência recalculada
```sql
SELECT
    pc.produto_id,
    pc.qtde_pedida,
    pc.qtde_entregue,
    pc.qtde_pendente                                     AS pendente_origem,
    COALESCE(SUM(em.qtde_recebida), 0)                   AS recebido_recalculado,
    pc.qtde_pedida - COALESCE(SUM(em.qtde_recebida), 0)  AS pendente_recalculado
FROM systock.pedido_compra pc
LEFT JOIN systock.entradas_mercadoria em
       ON em.ordem_compra = pc.ordem_compra
      AND em.produto_id   = pc.produto_id
WHERE pc.ordem_compra <> 0
GROUP BY pc.produto_id, pc.qtde_pedida, pc.qtde_entregue, pc.qtde_pendente
HAVING pc.qtde_pendente <> (pc.qtde_pedida - COALESCE(SUM(em.qtde_recebida), 0))
ORDER BY pc.produto_id;
```
Uso na reunião: evidência direta e objetiva do item 1.4 — mostra lado a
lado o valor que vem do sistema e o valor recalculado, para o cliente
confirmar qual está correto.

### 3.4 Pedidos sem vínculo de ordem de compra
```sql
SELECT
    pc.produto_id,
    pc.pedido_id,
    pc.descricao_produto,
    pc.fornecedor_id,
    pc.qtde_pedida
FROM systock.pedido_compra pc
WHERE pc.ordem_compra = 0
ORDER BY pc.produto_id;
```
Uso na reunião: lista objetiva para o cliente classificar, registro a
registro, se são pedidos válidos ou lixo de integração (item 1.5).

### 3.5 Produtos sem fornecedor vinculado
```sql
SELECT filial_id, produto_id, descricao
FROM systock.produtos_filial
WHERE idfonecedor IS NULL
ORDER BY produto_id;
```
Uso na reunião: se a lista voltar vazia após o backfill, perguntar
diretamente se a regra de atribuição automática usada (fornecedor de menor
ID) é aceitável como fallback ou se cada produto precisa de vínculo manual
revisado pelo cliente (item 1.6).

---

## Observação final

Nenhum desses seis pontos foi corrigido "silenciosamente" no pipeline — a
estratégia adotada foi sempre carregar o dado da forma mais fiel possível à
origem e expor as inconsistências através de consultas, para que a decisão
final sobre como tratá-las (descartar, recalcular, ou manter como está)
seja do cliente, não do time de implantação.
