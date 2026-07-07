-- ============================================================================
-- CASE TÉCNICO SYSTOCK — Parte 2 (Consultas Básicas) e Parte 3 (Transformações)
-- Schema: systock
-- ============================================================================


-- ============================================================================
-- PARTE 2.1 — CONSUMO POR PRODUTO E MÊS
-- Total de vendas (quantidade e valor em R$) de cada produto em fev/2025.
-- ============================================================================
SELECT
    v.produto_id,
    SUM(v.qtde_vendida)                      AS qtde_total_vendida,
    SUM(v.qtde_vendida * v.valor_unitario)   AS valor_total_vendido
FROM systock.venda v
WHERE v.data_emissao >= DATE '2025-02-01'
  AND v.data_emissao <  DATE '2025-03-01'
GROUP BY v.produto_id
ORDER BY v.produto_id;


-- ============================================================================
-- PARTE 2.2 — PRODUTOS COM REQUISIÇÃO PENDENTE
-- Produtos que foram requisitados (pedido de compra) mas ainda não foram
-- recebidos (sem entrada de mercadoria correspondente, ou entrada parcial).
-- ============================================================================

-- Versão simples: usa a própria coluna qtde_pendente já calculada no pedido.
SELECT
    pc.produto_id,
    pc.descricao_produto,
    pc.pedido_id,
    pc.qtde_pedida,
    pc.qtde_entregue,
    pc.qtde_pendente
FROM systock.pedido_compra pc
WHERE pc.qtde_pendente > 0
ORDER BY pc.produto_id;

-- Versão cruzada com entradas_mercadoria (mais robusta): calcula a pendência
-- de fato, comparando o que foi pedido com o que foi efetivamente recebido
-- via ORDEM_COMPRA (conforme observação do enunciado), sem depender apenas
-- do valor pré-calculado em qtde_pendente (que pode estar desatualizado
-- ou ser um dos pontos a validar com o cliente).
--
-- IMPORTANTE: alguns registros de pedido_compra vieram com ORDEM_COMPRA
-- vazio na origem (carregado como 0 por default na Parte 1). Esses casos
-- NÃO podem ser cruzados com entradas_mercadoria de forma confiável — não
-- significa "0% recebido", significa "sem vínculo pra verificar". Por isso
-- são segregados abaixo em vez de contados como pendência real.

-- 2.2a) Pendência REAL (pedidos com ordem_compra válida, cruzados de fato)
SELECT
    pc.produto_id,
    pc.descricao_produto,
    pc.ordem_compra,
    pc.qtde_pedida,
    COALESCE(SUM(em.qtde_recebida), 0)              AS qtde_recebida_real,
    pc.qtde_pedida - COALESCE(SUM(em.qtde_recebida), 0) AS qtde_pendente_calculada
FROM systock.pedido_compra pc
LEFT JOIN systock.entradas_mercadoria em
       ON em.ordem_compra = pc.ordem_compra
      AND em.produto_id   = pc.produto_id
WHERE pc.ordem_compra <> 0
GROUP BY pc.produto_id, pc.descricao_produto, pc.ordem_compra, pc.qtde_pedida
HAVING pc.qtde_pedida - COALESCE(SUM(em.qtde_recebida), 0) > 0
ORDER BY pc.produto_id;

-- 2.2b) Pedidos SEM vínculo de ordem_compra na origem (não dá pra concluir
-- se foram recebidos ou não — reportar à parte na validação com o cliente)
SELECT
    pc.produto_id,
    pc.descricao_produto,
    pc.pedido_id,
    pc.qtde_pedida,
    pc.qtde_entregue,
    pc.qtde_pendente
FROM systock.pedido_compra pc
WHERE pc.ordem_compra = 0
ORDER BY pc.produto_id;


-- ============================================================================
-- PARTE 3.1 — CONCATENAÇÃO produto_id + descricao_produto
-- Formato: "12345 - Detergente". Onde não houver descrição, mostra só o id.
-- ============================================================================

-- pedido_compra
SELECT
    pc.produto_id || COALESCE(' - ' || pc.descricao_produto, '') AS produto,
    pc.*
FROM systock.pedido_compra pc;

-- entradas_mercadoria
SELECT
    em.produto_id || COALESCE(' - ' || em.descricao_produto, '') AS produto,
    em.*
FROM systock.entradas_mercadoria em;

-- produtos_filial (usa a coluna "descricao")
SELECT
    pf.produto_id || COALESCE(' - ' || pf.descricao, '') AS produto,
    pf.*
FROM systock.produtos_filial pf;


-- ============================================================================
-- PARTE 3.2 — FORMATAÇÃO DE DATAS PARA DD/MM/YYYY
-- (formato de EXIBIÇÃO — diferente do formato de entrada do CSV, que era
-- misto: MM/DD/YYYY e ISO YYYY-MM-DD, já tratado na carga)
-- ============================================================================

SELECT venda_id, to_char(data_emissao, 'DD/MM/YYYY') AS data_emissao_br
FROM systock.venda;

SELECT pedido_id, produto_id,
       to_char(data_pedido, 'DD/MM/YYYY')  AS data_pedido_br,
       to_char(data_entrega, 'DD/MM/YYYY') AS data_entrega_br
FROM systock.pedido_compra;

SELECT nro_nfe, produto_id, to_char(data_entrada, 'DD/MM/YYYY') AS data_entrada_br
FROM systock.entradas_mercadoria;


-- ============================================================================
-- PARTE 3.3 — PRODUTOS REQUISITADOS MAIS DE 10 VEZES NO PERÍODO
-- "Requisitado" = número de linhas de pedido_compra por produto (cada linha
-- é uma requisição). Ajuste o HAVING/period conforme a base crescer.
-- Formato de saída conforme exemplo do enunciado:
--   Produto | Qtde Requisitada | Data Solicitação
-- ============================================================================
SELECT
    pc.produto_id || COALESCE(' - ' || pc.descricao_produto, '') AS produto,
    COUNT(*)                                    AS qtde_requisitada,
    to_char(MIN(pc.data_pedido), 'DD/MM/YYYY')  AS data_solicitacao
FROM systock.pedido_compra pc
GROUP BY pc.produto_id, pc.descricao_produto
HAVING COUNT(*) > 10
ORDER BY qtde_requisitada DESC;

-- Observação: com a base atual (29 pedidos carregados), é esperado que essa
-- consulta retorne 0 linhas — é o comportamento correto do filtro "> 10",
-- não um erro. Vale citar esse ponto na documentação/validação com o
-- cliente, já que ele pode estranhar um resultado vazio à primeira vista.


-- ============================================================================
-- PARTE 3.4 — TRIGGER: gerar idfornecedor numérico automaticamente
-- ============================================================================
-- CONTEXTO / PROBLEMA DE DESIGN IDENTIFICADO:
-- systock.fornecedor.idfornecedor é VARCHAR (chave de negócio, ex: "FORN01"),
-- enquanto systock.produtos_filial.idfonecedor é INT4 (esperando um valor
-- numérico). Não é possível relacionar os dois diretamente sem um "de-para"
-- numérico. A solução abaixo:
--   1) Adiciona uma coluna numérica (surrogate key) em fornecedor, gerada
--      via SEQUENCE + TRIGGER (não via SERIAL, para explicitar o uso de
--      trigger conforme pedido no enunciado).
--   2) Cria uma trigger em produtos_filial que, ao inserir/atualizar um
--      produto sem idfonecedor preenchido, busca o próximo fornecedor
--      disponível (regra simplificada: o de menor id numérico ainda não
--      utilizado) e usa esse numérico. Ajuste a regra de negócio real com
--      o cliente na validação (Parte 4) — aqui a lacuna é registrada como
--      um ponto a esclarecer, não uma regra definitiva.
-- ============================================================================

-- 1) Sequence + coluna numérica em fornecedor
CREATE SEQUENCE IF NOT EXISTS systock.seq_fornecedor_num_id START 1;

ALTER TABLE systock.fornecedor
    ADD COLUMN IF NOT EXISTS fornecedor_num_id int4;

CREATE OR REPLACE FUNCTION systock.fn_gera_fornecedor_num_id()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.fornecedor_num_id IS NULL THEN
        NEW.fornecedor_num_id := nextval('systock.seq_fornecedor_num_id');
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_gera_fornecedor_num_id ON systock.fornecedor;
CREATE TRIGGER trg_gera_fornecedor_num_id
    BEFORE INSERT ON systock.fornecedor
    FOR EACH ROW
    EXECUTE FUNCTION systock.fn_gera_fornecedor_num_id();

-- Backfill: gera o numérico para fornecedores que já existiam antes da trigger
UPDATE systock.fornecedor
SET fornecedor_num_id = nextval('systock.seq_fornecedor_num_id')
WHERE fornecedor_num_id IS NULL;

-- 2) Trigger em produtos_filial: preenche idfonecedor automaticamente
--    quando vier nulo, associando ao fornecedor_num_id já existente.
CREATE OR REPLACE FUNCTION systock.fn_gera_idfonecedor_produto()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_fornecedor_num_id int4;
BEGIN
    IF NEW.idfonecedor IS NULL THEN
        SELECT fornecedor_num_id
          INTO v_fornecedor_num_id
          FROM systock.fornecedor
         ORDER BY fornecedor_num_id
         LIMIT 1;

        NEW.idfonecedor := v_fornecedor_num_id;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_gera_idfonecedor_produto ON systock.produtos_filial;
CREATE TRIGGER trg_gera_idfonecedor_produto
    BEFORE INSERT ON systock.produtos_filial
    FOR EACH ROW
    EXECUTE FUNCTION systock.fn_gera_idfonecedor_produto();

-- Teste rápido da trigger (opcional):
-- INSERT INTO systock.produtos_filial (filial_id, produto_id, descricao, estoque, preco_unitario, preco_compra, preco_venda)
-- VALUES (1, 'TESTE_TRIGGER', 'Produto Teste', 0, 0, 0, 0);
-- SELECT produto_id, idfonecedor FROM systock.produtos_filial WHERE produto_id = 'TESTE_TRIGGER';

-- ============================================================================
-- BACKFILL: as 20 linhas de produtos_filial carregadas na Parte 1 já
-- existiam ANTES da trigger ser criada — por isso ficaram com idfonecedor
-- NULL (a trigger só age em INSERT novo, não retroage sobre dado existente).
-- Este UPDATE aplica a mesma regra da trigger nas linhas antigas.
-- ============================================================================
UPDATE systock.produtos_filial
SET idfonecedor = (
    SELECT fornecedor_num_id
      FROM systock.fornecedor
     ORDER BY fornecedor_num_id
     LIMIT 1
)
WHERE idfonecedor IS NULL;

-- Conferência: não deve sobrar nenhuma linha NULL após o backfill.
SELECT count(*) AS ainda_nulo
FROM systock.produtos_filial
WHERE idfonecedor IS NULL;