// Export only the currently rendered, authorized list page, never hidden records.
export function csvCell(value){let s=String(value??'');if(/^[\s]*[=+\-@\t\r]/.test(s))s="'"+s;return '"'+s.replaceAll('"','""')+'"'}
export function downloadVisibleTable(table,filename){
 if(!table)return;
 const headers=[...table.querySelectorAll('thead th')];
 const rows=[...table.querySelectorAll('tbody tr')];
 const columns=headers.map((_,i)=>i).filter(i=>!rows.some(r=>r.cells[i]?.querySelector('button,input,select,textarea,a')));
 if(!columns.length)return;
 const values=[columns.map(i=>headers[i].textContent),...rows.map(r=>columns.map(i=>r.cells[i]?.textContent??''))];
 downloadCsvRows(values,filename)
}
export function downloadCsvRows(values,filename){
 const url=URL.createObjectURL(new Blob(['\uFEFF'+values.map(row=>row.map(csvCell).join(',')).join('\r\n')],{type:'text/csv;charset=utf-8'}));
 const a=document.createElement('a');a.href=url;a.download=filename;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000)
}
