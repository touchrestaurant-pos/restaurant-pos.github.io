-- Donuts: ingredients by the gram, packaging, menu items and recipes. Safe to run twice.
insert into public.stock_items (name, category, unit, qty_on_hand, min_level, avg_cost, supplier_id, purchase_unit, purchase_factor, vat_type)
select v.name, v.category, v.unit, v.qty, v.min_level, v.cost, (select id from public.suppliers s where s.name = v.supplier), v.pack, v.factor, 'standard'
from (values
  ('Donut dough premix',        'Donut ingredients', 'g', 25000, 10000, 0.0220, 'Metro Foods Wholesale', 'bag', 12500),
  ('White sugar',               'Donut ingredients', 'g', 10000,  4000, 0.0240, 'Metro Foods Wholesale', 'bag', 2500),
  ('Ground cinnamon',           'Donut ingredients', 'g',  1000,   300, 0.3200, 'Metro Foods Wholesale', 'tub', 500),
  ('Icing sugar',               'Donut ingredients', 'g',  8000,  3000, 0.0350, 'Metro Foods Wholesale', 'bag', 1000),
  ('Milk chocolate',            'Donut ingredients', 'g',  5000,  2000, 0.1400, 'Metro Foods Wholesale', 'slab', 2500),
  ('White chocolate',           'Donut ingredients', 'g',  3000,  1000, 0.1600, 'Metro Foods Wholesale', 'slab', 2500),
  ('Dark chocolate',            'Donut ingredients', 'g',  3000,  1000, 0.1500, 'Metro Foods Wholesale', 'slab', 2500),
  ('Caramel sauce',             'Donut ingredients', 'g',  3000,  1000, 0.0700, 'Metro Foods Wholesale', 'tub', 1000),
  ('Custard filling',           'Donut ingredients', 'g',  4000,  1500, 0.0500, 'Metro Foods Wholesale', 'tub', 2000),
  ('Strawberry jam',            'Donut ingredients', 'g',  4000,  1500, 0.0450, 'Metro Foods Wholesale', 'tub', 2000),
  ('Rainbow sprinkles',         'Donut ingredients', 'g',  1500,   500, 0.1200, 'Metro Foods Wholesale', 'tub', 500),
  ('Cookie crumbs',             'Donut ingredients', 'g',  1500,   500, 0.1100, 'Metro Foods Wholesale', 'bag', 500),
  ('Caramelised biscuit spread','Donut ingredients', 'g',  2000,   800, 0.1900, 'Metro Foods Wholesale', 'tub', 1000),
  ('Hazelnut chocolate spread', 'Donut ingredients', 'g',  2000,   800, 0.1500, 'Metro Foods Wholesale', 'tub', 1000),
  ('Chopped nuts',              'Donut ingredients', 'g',  1000,   400, 0.2200, 'Metro Foods Wholesale', 'bag', 500),
  ('Donut box (single)',        'Packaging', 'pc',  300,  100, 1.8000, 'PackRight Packaging', 'sleeve', 100),
  ('Donut box (6)',             'Packaging', 'pc',  150,   50, 4.5000, 'PackRight Packaging', 'pack', 50),
  ('Donut box (12)',            'Packaging', 'pc',  100,   30, 7.5000, 'PackRight Packaging', 'pack', 25),
  ('Wax paper sheet',           'Packaging', 'pc', 2000,  500, 0.1500, 'PackRight Packaging', 'pack', 500),
  ('Paper bag (small)',         'Packaging', 'pc', 1000,  300, 0.3500, 'PackRight Packaging', 'pack', 500),
  ('Serviette',                 'Packaging', 'pc', 3000, 1000, 0.0800, 'PackRight Packaging', 'pack', 500),
  ('Paper cup 250ml',           'Packaging', 'pc',  500,  200, 1.1000, 'PackRight Packaging', 'sleeve', 50),
  ('Plastic lid (250ml cup)',   'Packaging', 'pc',  500,  200, 0.4500, 'PackRight Packaging', 'sleeve', 50),
  ('Plastic dome lid (milkshake cup)', 'Packaging', 'pc', 300, 100, 0.5500, 'PackRight Packaging', 'sleeve', 50)
) as v(name, category, unit, qty, min_level, cost, supplier, pack, factor)
where not exists (select 1 from public.stock_items si where si.name = v.name);

insert into public.products (category_id, name, description, price, sort_order)
select (select id from public.categories where name = 'Donuts' limit 1), v.name, v.descr, v.price, 20 + v.ord
from (values
  (1,  'Classic Glazed Donut',        'Soft ring donut with vanilla glaze', 14.90),
  (2,  'Cinnamon Sugar Donut',        'Rolled in cinnamon sugar', 12.90),
  (3,  'Chocolate Glazed Donut',      'Dipped in milk chocolate', 16.90),
  (4,  'White Choc Drizzle Donut',    'White chocolate with a milk chocolate drizzle', 17.90),
  (5,  'Dark Chocolate Donut',        'Dipped in dark chocolate', 17.90),
  (6,  'Sprinkle Party Donut',        'Vanilla glaze and rainbow sprinkles', 16.90),
  (7,  'Strawberry Jam Donut',        'Filled with strawberry jam', 18.90),
  (8,  'Custard Filled Donut',        'Filled with vanilla custard', 18.90),
  (9,  'Caramel Crunch Donut',        'Caramel topping and chopped nuts', 19.90),
  (10, 'Cookies and Cream Donut',     'White chocolate and cookie crumbs', 21.90),
  (11, 'Caramelised Biscuit Donut',   'Biscuit spread and cookie crumbs', 22.90),
  (12, 'Hazelnut Choc Filled Donut',  'Filled with hazelnut chocolate spread', 22.90),
  (13, 'Choc Nut Donut',              'Milk chocolate and chopped nuts', 19.90),
  (14, 'Mini Cinnamon Donuts (6)',    'Six mini donuts in cinnamon sugar', 29.90),
  (15, 'Box of 6 Assorted Donuts',    'Six donuts, mixed toppings', 89.90),
  (16, 'Box of 12 Assorted Donuts',   'Twelve donuts, mixed toppings', 169.90),
  (17, 'Donut and Coffee',            'Classic glazed donut with a coffee', 34.90)
) as v(ord, name, descr, price)
where not exists (select 1 from public.products p where p.name = v.name);

insert into public.recipe_lines (product_id, stock_item_id, qty)
select p.id, si.id, v.qty
from (values
  -- every single donut: dough, frying oil, wax paper, serviette
  ('Classic Glazed Donut','Donut dough premix',60),('Classic Glazed Donut','Cooking oil',0.008),('Classic Glazed Donut','Wax paper sheet',1),('Classic Glazed Donut','Serviette',1),('Classic Glazed Donut','Icing sugar',25),
  ('Cinnamon Sugar Donut','Donut dough premix',60),('Cinnamon Sugar Donut','Cooking oil',0.008),('Cinnamon Sugar Donut','Wax paper sheet',1),('Cinnamon Sugar Donut','Serviette',1),('Cinnamon Sugar Donut','White sugar',12),('Cinnamon Sugar Donut','Ground cinnamon',1.5),
  ('Chocolate Glazed Donut','Donut dough premix',60),('Chocolate Glazed Donut','Cooking oil',0.008),('Chocolate Glazed Donut','Wax paper sheet',1),('Chocolate Glazed Donut','Serviette',1),('Chocolate Glazed Donut','Milk chocolate',22),
  ('White Choc Drizzle Donut','Donut dough premix',60),('White Choc Drizzle Donut','Cooking oil',0.008),('White Choc Drizzle Donut','Wax paper sheet',1),('White Choc Drizzle Donut','Serviette',1),('White Choc Drizzle Donut','White chocolate',20),('White Choc Drizzle Donut','Milk chocolate',5),
  ('Dark Chocolate Donut','Donut dough premix',60),('Dark Chocolate Donut','Cooking oil',0.008),('Dark Chocolate Donut','Wax paper sheet',1),('Dark Chocolate Donut','Serviette',1),('Dark Chocolate Donut','Dark chocolate',22),
  ('Sprinkle Party Donut','Donut dough premix',60),('Sprinkle Party Donut','Cooking oil',0.008),('Sprinkle Party Donut','Wax paper sheet',1),('Sprinkle Party Donut','Serviette',1),('Sprinkle Party Donut','Icing sugar',20),('Sprinkle Party Donut','Rainbow sprinkles',6),
  ('Strawberry Jam Donut','Donut dough premix',60),('Strawberry Jam Donut','Cooking oil',0.008),('Strawberry Jam Donut','Wax paper sheet',1),('Strawberry Jam Donut','Serviette',1),('Strawberry Jam Donut','Strawberry jam',30),('Strawberry Jam Donut','Icing sugar',5),
  ('Custard Filled Donut','Donut dough premix',60),('Custard Filled Donut','Cooking oil',0.008),('Custard Filled Donut','Wax paper sheet',1),('Custard Filled Donut','Serviette',1),('Custard Filled Donut','Custard filling',35),('Custard Filled Donut','Icing sugar',5),
  ('Caramel Crunch Donut','Donut dough premix',60),('Caramel Crunch Donut','Cooking oil',0.008),('Caramel Crunch Donut','Wax paper sheet',1),('Caramel Crunch Donut','Serviette',1),('Caramel Crunch Donut','Caramel sauce',25),('Caramel Crunch Donut','Chopped nuts',6),
  ('Cookies and Cream Donut','Donut dough premix',60),('Cookies and Cream Donut','Cooking oil',0.008),('Cookies and Cream Donut','Wax paper sheet',1),('Cookies and Cream Donut','Serviette',1),('Cookies and Cream Donut','White chocolate',18),('Cookies and Cream Donut','Cookie crumbs',10),
  ('Caramelised Biscuit Donut','Donut dough premix',60),('Caramelised Biscuit Donut','Cooking oil',0.008),('Caramelised Biscuit Donut','Wax paper sheet',1),('Caramelised Biscuit Donut','Serviette',1),('Caramelised Biscuit Donut','Caramelised biscuit spread',25),('Caramelised Biscuit Donut','Cookie crumbs',4),
  ('Hazelnut Choc Filled Donut','Donut dough premix',60),('Hazelnut Choc Filled Donut','Cooking oil',0.008),('Hazelnut Choc Filled Donut','Wax paper sheet',1),('Hazelnut Choc Filled Donut','Serviette',1),('Hazelnut Choc Filled Donut','Hazelnut chocolate spread',30),('Hazelnut Choc Filled Donut','Milk chocolate',8),
  ('Choc Nut Donut','Donut dough premix',60),('Choc Nut Donut','Cooking oil',0.008),('Choc Nut Donut','Wax paper sheet',1),('Choc Nut Donut','Serviette',1),('Choc Nut Donut','Milk chocolate',20),('Choc Nut Donut','Chopped nuts',6),
  ('Mini Cinnamon Donuts (6)','Donut dough premix',120),('Mini Cinnamon Donuts (6)','Cooking oil',0.015),('Mini Cinnamon Donuts (6)','White sugar',20),('Mini Cinnamon Donuts (6)','Ground cinnamon',3),('Mini Cinnamon Donuts (6)','Paper bag (small)',1),('Mini Cinnamon Donuts (6)','Serviette',2),
  ('Box of 6 Assorted Donuts','Donut dough premix',360),('Box of 6 Assorted Donuts','Cooking oil',0.048),('Box of 6 Assorted Donuts','Icing sugar',60),('Box of 6 Assorted Donuts','Milk chocolate',50),('Box of 6 Assorted Donuts','Rainbow sprinkles',10),('Box of 6 Assorted Donuts','Caramel sauce',25),('Box of 6 Assorted Donuts','Strawberry jam',30),('Box of 6 Assorted Donuts','Donut box (6)',1),('Box of 6 Assorted Donuts','Wax paper sheet',6),('Box of 6 Assorted Donuts','Serviette',6),
  ('Box of 12 Assorted Donuts','Donut dough premix',720),('Box of 12 Assorted Donuts','Cooking oil',0.096),('Box of 12 Assorted Donuts','Icing sugar',120),('Box of 12 Assorted Donuts','Milk chocolate',100),('Box of 12 Assorted Donuts','Rainbow sprinkles',20),('Box of 12 Assorted Donuts','Caramel sauce',50),('Box of 12 Assorted Donuts','Strawberry jam',60),('Box of 12 Assorted Donuts','Donut box (12)',1),('Box of 12 Assorted Donuts','Wax paper sheet',12),('Box of 12 Assorted Donuts','Serviette',12),
  ('Donut and Coffee','Donut dough premix',60),('Donut and Coffee','Cooking oil',0.008),('Donut and Coffee','Wax paper sheet',1),('Donut and Coffee','Serviette',1),('Donut and Coffee','Icing sugar',25),('Donut and Coffee','Coffee beans',14),('Donut and Coffee','Milk',0.05),('Donut and Coffee','Paper cup 250ml',1),('Donut and Coffee','Plastic lid (250ml cup)',1)
) as v(product, item, qty)
join public.products p on p.name = v.product
join public.stock_items si on si.name = v.item
where not exists (select 1 from public.recipe_lines r where r.product_id = p.id and r.stock_item_id = si.id);
