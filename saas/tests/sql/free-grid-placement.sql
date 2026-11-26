do $test$ declare v jsonb:='{"pages":[{"slug":"home","title":"Home","blocks":[{"type":"text","title":"A","body":"","image":"","action":"none","tone":"surface","layout":{"desktop":6,"mobile":6,"align":"start","padding":"normal","image_fit":"natural","heading":"normal","position":{"desktop_column":7,"desktop_row":2,"mobile_column":1,"mobile_row":1}}}]}],"images":[],"product_images":{},"desktop":{"layout":"cards","columns":3,"density":"normal"},"mobile":{"layout":"cards","columns":1,"density":"normal"}}'::jsonb; b jsonb;begin
 if not tenant_private.valid_site(v) then raise exception 'Valid placement rejected';end if;
 b:=v#>'{pages,0,blocks,0}';
 if tenant_private.valid_site(jsonb_set(v,'{pages,0,blocks}',jsonb_build_array(b,b))) then raise exception 'Overlap accepted';end if;
 if tenant_private.valid_site(jsonb_set(v,'{pages,0,blocks,0,layout,position,desktop_column}','8')) then raise exception 'Invalid column accepted';end if;
 if not tenant_private.valid_site(v#-'{pages,0,blocks,0,layout,position}') then raise exception 'Legacy layout rejected';end if;
 if not tenant_private.valid_site(jsonb_set(v,'{pages,0,blocks}',jsonb_build_array(b,jsonb_set(jsonb_set(b,'{layout,position,desktop_column}','1'),'{layout,position,mobile_column}','7')))) then raise exception 'Nonoverlapping positions rejected';end if;
end; $test$;