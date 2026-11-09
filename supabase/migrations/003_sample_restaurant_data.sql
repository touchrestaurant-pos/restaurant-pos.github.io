-- Sample fast-food restaurant data in Rands (VAT 15%, prices include VAT).
-- Replace with your real menu, stock and suppliers from the admin screens.

update public.company_settings set
  company_name = 'Grill House (Pty) Ltd', trading_name = 'Grill House',
  phone = '012 345 6789', email = 'info@grillhouse.example',
  address = '123 Church Street, Pretoria, 0002',
  vat_number = '4012345678', reg_number = '2020/123456/07',
  receipt_footer = 'Thank you for dining with us!'
where id = 1;

insert into public.suppliers (name, contact_person, phone, email) values
 ('Metro Foods Wholesale','Lerato Dlamini','012 555 0101','orders@metrofoods.example'),
 ('Fresh Fowl Poultry','Pieter van Wyk','012 555 0102','sales@freshfowl.example'),
 ('Prime Beef Supplies','Thabo Nkosi','012 555 0103','orders@primebeef.example'),
 ('Daily Bread Bakery','Aisha Patel','012 555 0104','orders@dailybread.example'),
 ('Valley Produce','Johan Botha','012 555 0105','sales@valleyproduce.example'),
 ('CoolDrinks Distribution','Mandla Khumalo','012 555 0106','orders@cooldrinks.example'),
 ('PackRight Packaging','Sarah Jacobs','012 555 0107','sales@packright.example');

insert into public.stock_items (name, category, unit, qty_on_hand, min_level, avg_cost, supplier_id)
select v.name, v.cat, v.unit, v.qty, v.minl, v.cost, s.id
from (values
 ('Chicken breast fillet (spicy)','Proteins','pc',148,80,12.40,'Fresh Fowl Poultry'),
 ('Chicken breast fillet (plain)','Proteins','pc',210,100,11.60,'Fresh Fowl Poultry'),
 ('Chicken wings','Proteins','pc',320,150,2.60,'Fresh Fowl Poultry'),
 ('Chicken strips','Proteins','pc',300,100,3.20,'Fresh Fowl Poultry'),
 ('Chicken quarter','Proteins','pc',44,30,14.00,'Fresh Fowl Poultry'),
 ('Beef patty','Proteins','pc',22,60,9.80,'Prime Beef Supplies'),
 ('Bacon rashers','Proteins','pc',160,60,2.60,'Prime Beef Supplies'),
 ('Hake fillet','Proteins','pc',0,30,11.50,'Metro Foods Wholesale'),
 ('Veggie patty','Proteins','pc',40,20,8.20,'Metro Foods Wholesale'),
 ('Burger bun (sesame)','Bakery','pc',96,100,2.60,'Daily Bread Bakery'),
 ('Kids bun','Bakery','pc',58,30,1.90,'Daily Bread Bakery'),
 ('Wrap tortilla','Bakery','pc',120,60,2.40,'Daily Bread Bakery'),
 ('Brownie (frozen)','Bakery','pc',45,20,8.50,'Daily Bread Bakery'),
 ('Cheddar cheese slice','Dairy','pc',310,120,1.35,'Metro Foods Wholesale'),
 ('Soft serve mix','Dairy','L',24,10,38.00,'Metro Foods Wholesale'),
 ('Milk','Dairy','L',30,12,14.50,'Metro Foods Wholesale'),
 ('Milkshake syrup - vanilla','Dairy','ml',3000,1000,0.040,'Metro Foods Wholesale'),
 ('Chocolate syrup','Dairy','ml',3000,1000,0.045,'Metro Foods Wholesale'),
 ('Lettuce','Produce','g',1800,800,0.037,'Valley Produce'),
 ('Tomato','Produce','g',3200,1000,0.028,'Valley Produce'),
 ('Onion','Produce','g',4500,1500,0.014,'Valley Produce'),
 ('Pickle slices','Produce','pc',540,200,0.13,'Valley Produce'),
 ('Mushrooms','Produce','g',2500,800,0.060,'Valley Produce'),
 ('Coleslaw mix','Produce','g',5000,1500,0.030,'Valley Produce'),
 ('Frozen chips','Frozen','g',38000,12000,0.026,'Metro Foods Wholesale'),
 ('Onion rings (frozen)','Frozen','g',6000,2000,0.055,'Metro Foods Wholesale'),
 ('Mayonnaise','Sauces','g',4200,1500,0.040,'Metro Foods Wholesale'),
 ('Peri-peri sauce','Sauces','ml',3000,1000,0.060,'Metro Foods Wholesale'),
 ('BBQ sauce','Sauces','ml',3500,1000,0.045,'Metro Foods Wholesale'),
 ('Burger sauce','Sauces','ml',2800,1000,0.050,'Metro Foods Wholesale'),
 ('Tartare sauce','Sauces','ml',1500,500,0.070,'Metro Foods Wholesale'),
 ('Tomato sauce sachet','Sauces','pc',900,300,0.45,'Metro Foods Wholesale'),
 ('Hot sauce (wings)','Sauces','ml',2000,600,0.070,'Metro Foods Wholesale'),
 ('Mushroom sauce','Sauces','ml',1800,600,0.060,'Metro Foods Wholesale'),
 ('Cooking oil','Dry goods','L',18,20,38.00,'Metro Foods Wholesale'),
 ('Spice coating mix','Dry goods','g',8000,2500,0.060,'Metro Foods Wholesale'),
 ('Salt','Dry goods','g',3000,1000,0.010,'Metro Foods Wholesale'),
 ('Cooldrink can 440ml','Drinks','pc',288,96,5.50,'CoolDrinks Distribution'),
 ('Bottled water 500ml','Drinks','pc',144,48,4.20,'CoolDrinks Distribution'),
 ('Iced tea bottle','Drinks','pc',72,24,6.50,'CoolDrinks Distribution'),
 ('Coffee beans','Drinks','g',3000,1000,0.250,'CoolDrinks Distribution'),
 ('Burger wrap paper','Packaging','pc',310,150,0.35,'PackRight Packaging'),
 ('Chip box (regular)','Packaging','pc',420,150,0.60,'PackRight Packaging'),
 ('Chip box (large)','Packaging','pc',330,100,0.85,'PackRight Packaging'),
 ('Wings box','Packaging','pc',250,80,1.10,'PackRight Packaging'),
 ('Milkshake cup','Packaging','pc',260,100,1.40,'PackRight Packaging'),
 ('Takeaway bag','Packaging','pc',400,150,0.70,'PackRight Packaging')
) as v(name, cat, unit, qty, minl, cost, sup)
join public.suppliers s on s.name = v.sup;

insert into public.categories (name, sort_order) values
 ('Burgers',1),('Chicken',2),('Wraps',3),('Sides',4),('Drinks',5),('Desserts',6),('Combos',7);

insert into public.products (category_id, name, description, price, sort_order)
select c.id, v.name, v.descr, v.price, v.sort
from (values
 ('Burgers','Chicken Burger','Crumbed fillet, mayo, lettuce, tomato',49.90,1),
 ('Burgers','Spicy Chicken Burger','Spicy fillet, mayo, lettuce, pickles',54.90,2),
 ('Burgers','Beef Burger','Beef patty, onion, tomato, burger sauce',52.90,3),
 ('Burgers','Double Beef Burger','Two patties, cheese, burger sauce',79.90,4),
 ('Burgers','Cheese Burger','Beef patty, cheddar, pickles',56.90,5),
 ('Burgers','Bacon Cheese Burger','Beef patty, bacon, cheddar',64.90,6),
 ('Burgers','BBQ Chicken Burger','Crumbed fillet, BBQ sauce, onion',57.90,7),
 ('Burgers','Peri-Peri Chicken Burger','Grilled fillet, peri-peri sauce',58.90,8),
 ('Burgers','Veggie Burger','Veggie patty, lettuce, tomato',49.90,9),
 ('Burgers','Fish Burger','Hake fillet, tartare sauce',54.90,10),
 ('Burgers','Mushroom Beef Burger','Beef patty, mushroom sauce',62.90,11),
 ('Burgers','Kids Burger','Small patty, plain bun',39.90,12),
 ('Chicken','6pc Wings','Six wings in hot sauce',69.90,1),
 ('Chicken','12pc Wings','Twelve wings in hot sauce',129.90,2),
 ('Chicken','Chicken Strips (5pc)','Five crumbed strips with burger sauce',64.90,3),
 ('Chicken','Quarter Chicken and Chips','Quarter chicken with regular chips',74.90,4),
 ('Chicken','Half Chicken and Chips','Half chicken with large chips',119.90,5),
 ('Wraps','Chicken Wrap','Fillet, lettuce, tomato, mayo',47.90,1),
 ('Wraps','Beef Wrap','Beef patty, onion, tomato, burger sauce',49.90,2),
 ('Wraps','Veggie Wrap','Veggie patty, lettuce, tomato, mayo',42.90,3),
 ('Sides','Regular Chips','Regular box',24.00,1),
 ('Sides','Large Chips','Large box',32.00,2),
 ('Sides','Onion Rings','Crumbed onion rings',28.00,3),
 ('Sides','Coleslaw','Creamy coleslaw',18.00,4),
 ('Sides','Garden Salad','Lettuce, tomato, onion',29.00,5),
 ('Drinks','Cooldrink 440ml','Can',18.00,1),
 ('Drinks','Bottled Water 500ml','Still water',14.00,2),
 ('Drinks','Iced Tea','Bottle',20.00,3),
 ('Drinks','Vanilla Milkshake','Thick vanilla shake',36.00,4),
 ('Drinks','Chocolate Milkshake','Thick chocolate shake',36.00,5),
 ('Drinks','Coffee','Fresh brewed with milk',24.00,6),
 ('Desserts','Soft Serve Cone','Vanilla soft serve',15.00,1),
 ('Desserts','Ice Cream Sundae','Soft serve with chocolate syrup',32.00,2),
 ('Desserts','Brownie','Warm chocolate brownie',28.00,3),
 ('Combos','Chicken Burger Combo','Chicken burger, regular chips, cooldrink',84.90,1),
 ('Combos','Spicy Chicken Burger Combo','Spicy burger, regular chips, cooldrink',89.90,2),
 ('Combos','Combo Meal - Beef','Beef burger, regular chips, cooldrink',87.90,3),
 ('Combos','Wings Combo','6pc wings, regular chips, cooldrink',104.90,4)
) as v(cat, name, descr, price, sort)
join public.categories c on c.name = v.cat;

insert into public.modifiers (name, price_delta) values
 ('No onion',0),('No mayo',0),('No pickles',0),('No sauce',0),('No tomato',0),('No salt',0),
 ('Extra cheese',8),('Extra hot sauce',3),('Extra bacon',12),('Well done',0),('Allergy - see note',0);

insert into public.recipe_lines (product_id, stock_item_id, qty)
select p.id, s.id, v.qty
from (values
 ('Chicken Burger','Chicken breast fillet (plain)',1),('Chicken Burger','Burger bun (sesame)',1),('Chicken Burger','Mayonnaise',20),('Chicken Burger','Lettuce',15),('Chicken Burger','Tomato',20),('Chicken Burger','Burger wrap paper',1),
 ('Spicy Chicken Burger','Chicken breast fillet (spicy)',1),('Spicy Chicken Burger','Burger bun (sesame)',1),('Spicy Chicken Burger','Mayonnaise',20),('Spicy Chicken Burger','Lettuce',15),('Spicy Chicken Burger','Pickle slices',3),('Spicy Chicken Burger','Burger wrap paper',1),
 ('Beef Burger','Beef patty',1),('Beef Burger','Burger bun (sesame)',1),('Beef Burger','Onion',15),('Beef Burger','Tomato',20),('Beef Burger','Burger sauce',20),('Beef Burger','Burger wrap paper',1),
 ('Double Beef Burger','Beef patty',2),('Double Beef Burger','Burger bun (sesame)',1),('Double Beef Burger','Cheddar cheese slice',2),('Double Beef Burger','Burger sauce',20),('Double Beef Burger','Burger wrap paper',1),
 ('Cheese Burger','Beef patty',1),('Cheese Burger','Burger bun (sesame)',1),('Cheese Burger','Cheddar cheese slice',1),('Cheese Burger','Pickle slices',3),('Cheese Burger','Burger sauce',15),('Cheese Burger','Burger wrap paper',1),
 ('Bacon Cheese Burger','Beef patty',1),('Bacon Cheese Burger','Burger bun (sesame)',1),('Bacon Cheese Burger','Cheddar cheese slice',1),('Bacon Cheese Burger','Bacon rashers',2),('Bacon Cheese Burger','Burger sauce',15),('Bacon Cheese Burger','Burger wrap paper',1),
 ('BBQ Chicken Burger','Chicken breast fillet (plain)',1),('BBQ Chicken Burger','Burger bun (sesame)',1),('BBQ Chicken Burger','BBQ sauce',25),('BBQ Chicken Burger','Onion',15),('BBQ Chicken Burger','Burger wrap paper',1),
 ('Peri-Peri Chicken Burger','Chicken breast fillet (plain)',1),('Peri-Peri Chicken Burger','Burger bun (sesame)',1),('Peri-Peri Chicken Burger','Peri-peri sauce',25),('Peri-Peri Chicken Burger','Lettuce',15),('Peri-Peri Chicken Burger','Burger wrap paper',1),
 ('Veggie Burger','Veggie patty',1),('Veggie Burger','Burger bun (sesame)',1),('Veggie Burger','Lettuce',15),('Veggie Burger','Tomato',20),('Veggie Burger','Mayonnaise',15),('Veggie Burger','Burger wrap paper',1),
 ('Fish Burger','Hake fillet',1),('Fish Burger','Burger bun (sesame)',1),('Fish Burger','Tartare sauce',20),('Fish Burger','Lettuce',15),('Fish Burger','Burger wrap paper',1),
 ('Mushroom Beef Burger','Beef patty',1),('Mushroom Beef Burger','Burger bun (sesame)',1),('Mushroom Beef Burger','Mushrooms',40),('Mushroom Beef Burger','Mushroom sauce',25),('Mushroom Beef Burger','Burger wrap paper',1),
 ('Kids Burger','Beef patty',1),('Kids Burger','Kids bun',1),('Kids Burger','Tomato sauce sachet',1),('Kids Burger','Burger wrap paper',1),
 ('6pc Wings','Chicken wings',6),('6pc Wings','Spice coating mix',30),('6pc Wings','Cooking oil',0.06),('6pc Wings','Hot sauce (wings)',20),('6pc Wings','Wings box',1),
 ('12pc Wings','Chicken wings',12),('12pc Wings','Spice coating mix',60),('12pc Wings','Cooking oil',0.12),('12pc Wings','Hot sauce (wings)',40),('12pc Wings','Wings box',1),
 ('Chicken Strips (5pc)','Chicken strips',5),('Chicken Strips (5pc)','Spice coating mix',25),('Chicken Strips (5pc)','Cooking oil',0.05),('Chicken Strips (5pc)','Burger sauce',30),('Chicken Strips (5pc)','Wings box',1),
 ('Quarter Chicken and Chips','Chicken quarter',1),('Quarter Chicken and Chips','Frozen chips',200),('Quarter Chicken and Chips','Cooking oil',0.08),('Quarter Chicken and Chips','Spice coating mix',20),('Quarter Chicken and Chips','Salt',3),('Quarter Chicken and Chips','Chip box (large)',1),
 ('Half Chicken and Chips','Chicken quarter',2),('Half Chicken and Chips','Frozen chips',250),('Half Chicken and Chips','Cooking oil',0.10),('Half Chicken and Chips','Spice coating mix',40),('Half Chicken and Chips','Salt',3),('Half Chicken and Chips','Chip box (large)',1),
 ('Chicken Wrap','Wrap tortilla',1),('Chicken Wrap','Chicken breast fillet (plain)',1),('Chicken Wrap','Lettuce',15),('Chicken Wrap','Tomato',20),('Chicken Wrap','Mayonnaise',20),('Chicken Wrap','Burger wrap paper',1),
 ('Beef Wrap','Wrap tortilla',1),('Beef Wrap','Beef patty',1),('Beef Wrap','Onion',15),('Beef Wrap','Tomato',20),('Beef Wrap','Burger sauce',20),('Beef Wrap','Burger wrap paper',1),
 ('Veggie Wrap','Wrap tortilla',1),('Veggie Wrap','Veggie patty',1),('Veggie Wrap','Lettuce',20),('Veggie Wrap','Tomato',20),('Veggie Wrap','Mayonnaise',15),('Veggie Wrap','Burger wrap paper',1),
 ('Regular Chips','Frozen chips',150),('Regular Chips','Cooking oil',0.04),('Regular Chips','Salt',2),('Regular Chips','Chip box (regular)',1),
 ('Large Chips','Frozen chips',250),('Large Chips','Cooking oil',0.06),('Large Chips','Salt',3),('Large Chips','Chip box (large)',1),
 ('Onion Rings','Onion rings (frozen)',120),('Onion Rings','Cooking oil',0.04),('Onion Rings','Chip box (regular)',1),
 ('Coleslaw','Coleslaw mix',100),('Coleslaw','Mayonnaise',15),
 ('Garden Salad','Lettuce',80),('Garden Salad','Tomato',60),('Garden Salad','Onion',20),
 ('Cooldrink 440ml','Cooldrink can 440ml',1),
 ('Bottled Water 500ml','Bottled water 500ml',1),
 ('Iced Tea','Iced tea bottle',1),
 ('Vanilla Milkshake','Soft serve mix',0.12),('Vanilla Milkshake','Milk',0.2),('Vanilla Milkshake','Milkshake syrup - vanilla',30),('Vanilla Milkshake','Milkshake cup',1),
 ('Chocolate Milkshake','Soft serve mix',0.12),('Chocolate Milkshake','Milk',0.2),('Chocolate Milkshake','Chocolate syrup',30),('Chocolate Milkshake','Milkshake cup',1),
 ('Coffee','Coffee beans',18),('Coffee','Milk',0.1),('Coffee','Milkshake cup',1),
 ('Soft Serve Cone','Soft serve mix',0.1),
 ('Ice Cream Sundae','Soft serve mix',0.15),('Ice Cream Sundae','Chocolate syrup',25),('Ice Cream Sundae','Milkshake cup',1),
 ('Brownie','Brownie (frozen)',1)
) as v(prod, stock, qty)
join public.products p on p.name = v.prod
join public.stock_items s on s.name = v.stock;

-- Combos are made from the recipes of their parts
insert into public.recipe_lines (product_id, stock_item_id, qty)
select cp.id, rl.stock_item_id, sum(rl.qty)
from (values
 ('Chicken Burger Combo','Chicken Burger'),('Chicken Burger Combo','Regular Chips'),('Chicken Burger Combo','Cooldrink 440ml'),
 ('Spicy Chicken Burger Combo','Spicy Chicken Burger'),('Spicy Chicken Burger Combo','Regular Chips'),('Spicy Chicken Burger Combo','Cooldrink 440ml'),
 ('Combo Meal - Beef','Beef Burger'),('Combo Meal - Beef','Regular Chips'),('Combo Meal - Beef','Cooldrink 440ml'),
 ('Wings Combo','6pc Wings'),('Wings Combo','Regular Chips'),('Wings Combo','Cooldrink 440ml')
) as v(combo, part)
join public.products cp on cp.name = v.combo
join public.products pp on pp.name = v.part
join public.recipe_lines rl on rl.product_id = pp.id
group by cp.id, rl.stock_item_id;

-- A sample draft GRV, ready to be posted from the stock screen
insert into public.grvs (grv_no, supplier_id, delivery_note, received_on, status, notes)
select 'GRV-000231', id, 'DN-20931', date '2026-11-09', 'draft', 'Sample draft GRV' from public.suppliers where name = 'Metro Foods Wholesale';

insert into public.grv_lines (grv_id, stock_item_id, ordered_qty, received_qty, unit_cost, expiry_date)
select g.id, s.id, v.ord, v.rec, v.cost, v.exp
from (values
 ('Chicken breast fillet (spicy)', 200, 200, 12.40, date '2026-11-20'),
 ('Beef patty', 120, 120, 9.80, date '2026-11-25'),
 ('Burger bun (sesame)', 240, 240, 2.60, date '2026-11-14')
) as v(item, ord, rec, cost, exp)
join public.stock_items s on s.name = v.item
join public.grvs g on g.grv_no = 'GRV-000231';
