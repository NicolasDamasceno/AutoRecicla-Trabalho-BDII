

CREATE TABLE filial (
    id_filial    SERIAL PRIMARY KEY,
    nome_unidade VARCHAR(100) NOT NULL,
    cidade       VARCHAR(100) NOT NULL,
    endereco     VARCHAR(200) NOT NULL,
    cnpj         VARCHAR(18)  NOT NULL UNIQUE
);

CREATE TABLE vendedor (
    id_vendedor SERIAL PRIMARY KEY,
    nome        VARCHAR(100) NOT NULL,
    cpf         VARCHAR(14)  NOT NULL UNIQUE,
    id_filial   INT          NOT NULL,
    ativo       BOOLEAN      NOT NULL DEFAULT TRUE,

    CONSTRAINT fk_vendedor_filial
        FOREIGN KEY (id_filial) REFERENCES filial(id_filial)
);

CREATE TABLE cliente (
    id_cliente SERIAL PRIMARY KEY,
    nome       VARCHAR(100) NOT NULL,
    cpf_cnpj   VARCHAR(18)  NOT NULL UNIQUE,
    telefone   VARCHAR(20),
    email      VARCHAR(150)
);

CREATE TABLE marca (
    id_marca   SERIAL PRIMARY KEY,
    nome_marca VARCHAR(100) NOT NULL UNIQUE
);

CREATE TABLE modelo (
    id_modelo   SERIAL PRIMARY KEY,
    nome_modelo VARCHAR(100) NOT NULL,
    id_marca    INT          NOT NULL,

    CONSTRAINT fk_modelo_marca
        FOREIGN KEY (id_marca) REFERENCES marca(id_marca)
);

CREATE TABLE categoria (
    id_categoria   SERIAL PRIMARY KEY,
    nome_categoria VARCHAR(100) NOT NULL UNIQUE
);

CREATE TABLE peca (
    id_peca    SERIAL PRIMARY KEY,
    nome_peca  VARCHAR(120)  NOT NULL,
    valor      NUMERIC(10,2) NOT NULL CHECK (valor > 0),

    estado_conservacao VARCHAR(20) NOT NULL
        CHECK (estado_conservacao IN ('Novo', 'Seminovo', 'Usado')),

    id_categoria INT NOT NULL,
    id_filial    INT NOT NULL,

    quantidade INT NOT NULL
        CHECK (quantidade >= 0),

    CONSTRAINT fk_peca_categoria
        FOREIGN KEY (id_categoria) REFERENCES categoria(id_categoria),

    CONSTRAINT fk_peca_filial
        FOREIGN KEY (id_filial) REFERENCES filial(id_filial),

    CONSTRAINT unq_peca_filial_estado
        UNIQUE (nome_peca, estado_conservacao, id_filial)
);

CREATE TABLE compatibilidade (
    id_comp   SERIAL PRIMARY KEY,
    id_peca   INT      NOT NULL,
    id_modelo INT      NOT NULL,

    ano_inicio SMALLINT NOT NULL,
    ano_fim    SMALLINT NOT NULL,

    CONSTRAINT fk_comp_peca
        FOREIGN KEY (id_peca)   REFERENCES peca(id_peca),

    CONSTRAINT fk_comp_modelo
        FOREIGN KEY (id_modelo) REFERENCES modelo(id_modelo),

    CONSTRAINT chk_anos
        CHECK (ano_inicio <= ano_fim),

    CONSTRAINT unq_comp_peca_modelo_anos
        UNIQUE (id_peca, id_modelo, ano_inicio, ano_fim)
);

-- valor_total é calculado e mantido via trigger
CREATE TABLE nota (
    id_nota    SERIAL PRIMARY KEY,

    data_criacao TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    data_venda   TIMESTAMP,

    status VARCHAR(20) NOT NULL DEFAULT 'Aberto'
        CHECK (status IN ('Aberto', 'Finalizado', 'Cancelado')),

    forma_pagamento VARCHAR(50)
        CHECK (
            forma_pagamento IS NULL OR
            forma_pagamento IN (
                'Pix', 'Dinheiro', 'Cartão de Crédito',
                'Cartão de Débito', 'Boleto'
            )
        ),

    valor_total NUMERIC(12,2) DEFAULT 0.00,

    id_cliente  INT NOT NULL,
    id_vendedor INT NOT NULL,

    CONSTRAINT fk_nota_cliente
        FOREIGN KEY (id_cliente)  REFERENCES cliente(id_cliente),

    CONSTRAINT fk_nota_vendedor
        FOREIGN KEY (id_vendedor) REFERENCES vendedor(id_vendedor)
);

CREATE TABLE nota_peca (
    id_nota  INT NOT NULL,
    id_peca  INT NOT NULL,

    valor_vendido NUMERIC(10,2) NOT NULL CHECK (valor_vendido > 0),

    quantidade INT NOT NULL CHECK (quantidade > 0),

    PRIMARY KEY (id_nota, id_peca),

    CONSTRAINT fk_notapeca_nota
        FOREIGN KEY (id_nota) REFERENCES nota(id_nota)
        ON DELETE CASCADE,

    CONSTRAINT fk_notapeca_peca
        FOREIGN KEY (id_peca) REFERENCES peca(id_peca)
);



--  TRIGGERS




--  Validar abertura de nota


CREATE OR REPLACE FUNCTION fn_validar_abertura_nota()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM vendedor
         WHERE id_vendedor = NEW.id_vendedor
           AND ativo = TRUE
    ) THEN
        RAISE EXCEPTION
            'Vendedor % está inativo e não pode abrir notas.',
            NEW.id_vendedor
            USING ERRCODE = 'P0001';
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER tg_validar_abertura_nota
    BEFORE INSERT ON nota
    FOR EACH ROW
    EXECUTE FUNCTION fn_validar_abertura_nota();



-- Bloquear desativação de vendedor com notas em aberto


CREATE OR REPLACE FUNCTION fn_bloquear_desativacao_vendedor()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.ativo = TRUE AND NEW.ativo = FALSE THEN
        IF EXISTS (
            SELECT 1 FROM nota
             WHERE id_vendedor = NEW.id_vendedor
               AND status = 'Aberto'
        ) THEN
            RAISE EXCEPTION
                'Vendedor % possui notas em aberto e não pode ser desativado.',
                NEW.id_vendedor
                USING ERRCODE = 'P0001';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER tg_bloquear_desativacao_vendedor
    BEFORE UPDATE OF ativo ON vendedor
    FOR EACH ROW
    EXECUTE FUNCTION fn_bloquear_desativacao_vendedor();



-- Validar filial do vendedor ao inserir item na nota


CREATE OR REPLACE FUNCTION fn_validar_filial_vendedor()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_filial_vendedor INT;
    v_filial_peca     INT;
BEGIN
    -- Bloqueia troca de PK — deve remover e reinserir
    IF TG_OP = 'UPDATE' THEN
        IF OLD.id_peca <> NEW.id_peca OR OLD.id_nota <> NEW.id_nota THEN
            RAISE EXCEPTION
                'Não é permitido alterar id_nota ou id_peca. Remova o item e insira novamente.'
                USING ERRCODE = 'P0001';
        END IF;
    END IF;

    -- Filial do vendedor que abriu a nota
    SELECT v.id_filial
      INTO v_filial_vendedor
      FROM nota n
      JOIN vendedor v ON v.id_vendedor = n.id_vendedor
     WHERE n.id_nota = NEW.id_nota;

    -- Filial onde a peça está registrada
    SELECT p.id_filial
      INTO v_filial_peca
      FROM peca p
     WHERE p.id_peca = NEW.id_peca;

    IF v_filial_vendedor IS DISTINCT FROM v_filial_peca THEN
        RAISE EXCEPTION
            'Filial incompatível: a peça % pertence à filial % mas o vendedor atua na filial %.',
            NEW.id_peca, v_filial_peca, v_filial_vendedor
            USING ERRCODE = 'P0001';
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER tg_validar_filial_vendedor
    BEFORE INSERT OR UPDATE ON nota_peca
    FOR EACH ROW
    EXECUTE FUNCTION fn_validar_filial_vendedor();



--Gerenciar estoque

CREATE OR REPLACE FUNCTION fn_gerenciar_estoque()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_status_nota VARCHAR(20);
    v_delta       INT := 0;
    v_id_peca     INT;
    v_qtd_atual   INT;
BEGIN
    IF TG_OP = 'DELETE' THEN
        SELECT status INTO v_status_nota FROM nota WHERE id_nota = OLD.id_nota;
        IF v_status_nota = 'Aberto' THEN
            v_delta   :=  OLD.quantidade;
            v_id_peca := OLD.id_peca;
        ELSE
            RETURN OLD;
        END IF;

    ELSIF TG_OP = 'INSERT' THEN
        SELECT status INTO v_status_nota FROM nota WHERE id_nota = NEW.id_nota;
        IF v_status_nota <> 'Aberto' THEN
            RAISE EXCEPTION
                'Não é possível adicionar itens a uma nota com status "%".',
                v_status_nota
                USING ERRCODE = 'P0001';
        END IF;
        v_delta   := -NEW.quantidade;
        v_id_peca :=  NEW.id_peca;

    ELSIF TG_OP = 'UPDATE' THEN
        SELECT status INTO v_status_nota FROM nota WHERE id_nota = NEW.id_nota;
        IF v_status_nota <> 'Aberto' THEN
            RAISE EXCEPTION
                'Não é possível alterar itens de uma nota com status "%".',
                v_status_nota
                USING ERRCODE = 'P0001';
        END IF;
        v_delta   := OLD.quantidade - NEW.quantidade;
        v_id_peca := NEW.id_peca;
    END IF;

    -- Verifica disponibilidade antes de reservar
    IF v_delta < 0 THEN
        SELECT quantidade INTO v_qtd_atual
          FROM peca WHERE id_peca = v_id_peca FOR UPDATE;

        IF v_qtd_atual + v_delta < 0 THEN
            RAISE EXCEPTION
                'Estoque insuficiente para a peça % (disponível: %, solicitado: %).',
                v_id_peca, v_qtd_atual, ABS(v_delta)
                USING ERRCODE = 'P0001';
        END IF;
    END IF;

    UPDATE peca
       SET quantidade = quantidade + v_delta
     WHERE id_peca = v_id_peca;

    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER tg_gerenciar_estoque
    AFTER INSERT OR UPDATE OR DELETE ON nota_peca
    FOR EACH ROW
    EXECUTE FUNCTION fn_gerenciar_estoque();



-- Recalcular valor_total da nota


CREATE OR REPLACE FUNCTION fn_recalcular_total()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_id_nota INT;
BEGIN
    v_id_nota := COALESCE(NEW.id_nota, OLD.id_nota);

    UPDATE nota
       SET valor_total = (
               SELECT COALESCE(SUM(np.valor_vendido * np.quantidade), 0.00)
                 FROM nota_peca np
                WHERE np.id_nota = v_id_nota
           )
     WHERE id_nota = v_id_nota;

    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER tg_recalcular_total
    AFTER INSERT OR UPDATE OR DELETE ON nota_peca
    FOR EACH ROW
    EXECUTE FUNCTION fn_recalcular_total();



CREATE OR REPLACE FUNCTION fn_ciclo_vida_nota()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    -- Protege valor_total e data_venda contra escrita direta
    -- (apenas os triggers internos podem alterá-los)
    IF NEW.status = OLD.status THEN
        NEW.valor_total := OLD.valor_total;
        NEW.data_venda  := OLD.data_venda;
        RETURN NEW;
    END IF;

    -- Bloqueia qualquer alteração em notas já encerradas
    IF OLD.status IN ('Finalizado', 'Cancelado') THEN
        RAISE EXCEPTION
            'Nota % está com status "%" e não pode ser alterada.',
            OLD.id_nota, OLD.status
            USING ERRCODE = 'P0001';
    END IF;

    -- Valida que a transição é para um status permitido
    IF NEW.status NOT IN ('Finalizado', 'Cancelado') THEN
        RAISE EXCEPTION
            'Transição de status inválida: "%" → "%".',
            OLD.status, NEW.status
            USING ERRCODE = 'P0001';
    END IF;

    -- Finalizar
    IF NEW.status = 'Finalizado' THEN
        IF NEW.forma_pagamento IS NULL THEN
            RAISE EXCEPTION
                'Informe a forma de pagamento antes de finalizar a nota %.',
                NEW.id_nota
                USING ERRCODE = 'P0001';
        END IF;

        IF NOT EXISTS (
            SELECT 1 FROM nota_peca WHERE id_nota = NEW.id_nota
        ) THEN
            RAISE EXCEPTION
                'A nota % não possui itens e não pode ser finalizada.',
                NEW.id_nota
                USING ERRCODE = 'P0001';
        END IF;

        NEW.data_venda := NOW();
    END IF;

    -- Cancelar: devolve estoque em lote
    IF NEW.status = 'Cancelado' THEN
        UPDATE peca p
           SET quantidade = p.quantidade + np.quantidade
          FROM nota_peca np
         WHERE np.id_nota = NEW.id_nota
           AND np.id_peca = p.id_peca;
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER tg_ciclo_vida_nota
    BEFORE UPDATE ON nota
    FOR EACH ROW
    EXECUTE FUNCTION fn_ciclo_vida_nota();



--Bloquear deleção de nota finalizada


CREATE OR REPLACE FUNCTION fn_bloquear_delete_nota()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.status = 'Finalizado' THEN
        RAISE EXCEPTION
            'Nota % está finalizada e não pode ser excluída.',
            OLD.id_nota
            USING ERRCODE = 'P0001';
    END IF;

    RETURN OLD;
END;
$$;

CREATE OR REPLACE TRIGGER tg_bloquear_delete_nota
    BEFORE DELETE ON nota
    FOR EACH ROW
    EXECUTE FUNCTION fn_bloquear_delete_nota();


