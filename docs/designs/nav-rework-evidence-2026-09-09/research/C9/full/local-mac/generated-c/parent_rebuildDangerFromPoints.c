N_LIB_PRIVATE N_NIMCALL(void, rebuildDangerFromPoints__OOZsrcZshellZbody95nav_u2191)(tyObject_BodyNavSeatcolonObjectType___0c87LTWzqtz7zmat1zT0Kw* seat_p0, tyObject_BodyMapcolonObjectType___bu6Wo0E0nSQBchq7gSI6UA* map_p1, tyTuple__1v9bKyksXWMsm0vNwmZ4EuQ* sources_p2, NI sources_p2Len_0, NI tick_p3) {
NIM_BOOL* nimErr_;
	nimfr_("rebuildDangerFromPoints", "body_nav.nim");
{nimErr_ = nimErrorFlag();
	{
		NF32* value_1;
		NI i_1;
		NI L_1;
		NI T2_;
		value_1 = (NF32*)0;
		i_1 = ((NI)0);
		T2_ = (*seat_p0).danger.values.len;
		L_1 = T2_;
		{
			while (1) {
				if (!(i_1 < L_1)) goto LA4;
				if (i_1 < 0 || i_1 >= (*seat_p0).danger.values.len){ raiseIndexError2(i_1,(*seat_p0).danger.values.len-1); goto BeforeRet_;
				}
				value_1 = (&(*seat_p0).danger.values.p->data[i_1]);
				(*value_1) = 0.0f;
				i_1 += ((NI)1);
				{
					NI T7_;
					T7_ = (*seat_p0).danger.values.len;
					if (!!((T7_ == L_1))) goto LA8_;
					failedAssertImpl__stdZassertions_u234(TM__fw0EGWK0CbR9aJ84zaF6cBg_245);
					if (NIM_UNLIKELY(*nimErr_)) goto BeforeRet_;
				}
LA8_: ;
			} LA4: ;
		}
	}
	{
		tyTuple__1v9bKyksXWMsm0vNwmZ4EuQ* source_1;
		NI i_2;
		source_1 = (tyTuple__1v9bKyksXWMsm0vNwmZ4EuQ*)0;
		i_2 = ((NI)0);
		{
			while (1) {
				tyObject_DangerSourceCachecolonObjectType___eF3OiM7VwQQb7PpdX1d3TQ* cache_1;
				tyTuple__1v9bKyksXWMsm0vNwmZ4EuQ origin_1;
				NI32 key_1;
				NI T13_;
				NI TM__fw0EGWK0CbR9aJ84zaF6cBg_246;
				NI TM__fw0EGWK0CbR9aJ84zaF6cBg_247;
				NI slot_1;
				NI closeRange_1;
				NI closeCells_1;
				NI TM__fw0EGWK0CbR9aJ84zaF6cBg_303;
				NI TM__fw0EGWK0CbR9aJ84zaF6cBg_304;
				NI closeSquared_1;
				NI TM__fw0EGWK0CbR9aJ84zaF6cBg_305;
				if (!(i_2 < sources_p2Len_0)) goto LA12;
				cache_1 = NIM_NIL;
				if (i_2 < 0 || i_2 >= sources_p2Len_0){ raiseIndexError2(i_2,sources_p2Len_0-1); goto BeforeRet_;
				}
				source_1 = (&sources_p2[i_2]);
				origin_1 = cellOf__OOZsrcZshellZbody95map_u527(map_p1, (*source_1));
				if (NIM_UNLIKELY(*nimErr_)) goto BeforeRet_;
				eqcopy___OOZsrcZshellZbody95nav_u975(&cache_1, (*seat_p0).dangerSourceCache);
				T13_ = (NI)0;
				T13_ = gridWidth__OOZsrcZshellZbody95map_u138(map_p1);
				if (NIM_UNLIKELY(*nimErr_)) goto BeforeRet_;
				if (nimMulInt(origin_1.Field1, T13_, &TM__fw0EGWK0CbR9aJ84zaF6cBg_246)) { raiseOverflow(); goto BeforeRet_;
				};
				if (nimAddInt((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_246), origin_1.Field0, &TM__fw0EGWK0CbR9aJ84zaF6cBg_247)) { raiseOverflow(); goto BeforeRet_;
				};
				if (((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_247)) < ((NI32)(-2147483647 -1)) || ((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_247)) > ((NI32)2147483647)){ raiseRangeErrorI((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_247), ((NI32)(-2147483647 -1)), ((NI32)2147483647)); goto BeforeRet_;
				}
				key_1 = ((NI32) ((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_247)));
				(*cache_1).clock += ((NI)1);
				slot_1 = sourceCacheSlot__OOZsrcZshellZbody95nav_u2148(cache_1, key_1);
				if (NIM_UNLIKELY(*nimErr_)) goto BeforeRet_;
				{
					NI TM__fw0EGWK0CbR9aJ84zaF6cBg_264;
					if (!(((NI)0) <= slot_1)) goto LA16_;
					if ((NU)(slot_1) > (NU)(63)){ raiseIndexError2(slot_1, 63); goto BeforeRet_;
					}
					(*cache_1).slots[(slot_1)- 0].lastUse = (*cache_1).clock;
					if (nimMulInt(slot_1, (*cache_1).words, &TM__fw0EGWK0CbR9aJ84zaF6cBg_264)) { raiseOverflow(); goto BeforeRet_;
					};
					replayVisibleCells__OOZsrcZshellZbody95nav_u2165(seat_p0, origin_1, (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_264));
					if (NIM_UNLIKELY(*nimErr_)) goto BeforeRet_;
				}
				goto LA14_;
LA16_: ;
				{
					NU64 colontmpD_;
					tyObject_DangerSourceCacheSlot__SJOelsyK1b9a9aCPCFgZqF5Q T19_;
					NI TM__fw0EGWK0CbR9aJ84zaF6cBg_266;
					colontmpD_ = (NU64)0;
					slot_1 = sourceCacheVictim__OOZsrcZshellZbody95nav_u2157(cache_1);
					if (NIM_UNLIKELY(*nimErr_)) goto BeforeRet_;
					if ((NU)(slot_1) > (NU)(63)){ raiseIndexError2(slot_1, 63); goto BeforeRet_;
					}
					T19_.key = key_1;
					colontmpD_ = (*cache_1).clock;
					T19_.lastUse = colontmpD_;
					(*cache_1).slots[(slot_1)- 0] = T19_;
					if (nimMulInt(slot_1, (*cache_1).words, &TM__fw0EGWK0CbR9aJ84zaF6cBg_266)) { raiseOverflow(); goto BeforeRet_;
					};
					(*seat_p0).dangerRecordBase = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_266);
					{
						NI word_1;
						NI i_3;
						word_1 = (NI)0;
						i_3 = ((NI)0);
						{
							while (1) {
								NI TM__fw0EGWK0CbR9aJ84zaF6cBg_267;
								NI TM__fw0EGWK0CbR9aJ84zaF6cBg_268;
								if (!(i_3 < (*cache_1).words)) goto LA22;
								word_1 = i_3;
								if (nimAddInt((*seat_p0).dangerRecordBase, word_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_267)) { raiseOverflow(); goto BeforeRet_;
								};
								if ((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_267) < 0 || (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_267) >= (*cache_1).bits.len){ raiseIndexError2((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_267),(*cache_1).bits.len-1); goto BeforeRet_;
								}
								(*cache_1).bits.p->data[(NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_267)] = 0ULL;
								if (nimAddInt(i_3, ((NI)1), &TM__fw0EGWK0CbR9aJ84zaF6cBg_268)) { raiseOverflow(); goto BeforeRet_;
								};
								i_3 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_268);
							} LA22: ;
						}
					}
					nextVisitGeneration__OOZsrcZshellZbody95nav_u2030(seat_p0);
					if (NIM_UNLIKELY(*nimErr_)) goto BeforeRet_;
					addVisibleCell__OOZsrcZshellZbody95nav_u2045(seat_p0, origin_1, (((*(*seat_p0).dangerGeometry).kernel).p) ? ((*(*seat_p0).dangerGeometry).kernel.p->data) : NIM_NIL, (*(*seat_p0).dangerGeometry).kernel.len, (*(*seat_p0).dangerGeometry).radius, origin_1.Field0, origin_1.Field1);
					if (NIM_UNLIKELY(*nimErr_)) goto BeforeRet_;
					{
						tyTuple__1v9bKyksXWMsm0vNwmZ4EuQ* offset_1;
						NI i_4;
						NI L_2;
						NI T24_;
						offset_1 = (tyTuple__1v9bKyksXWMsm0vNwmZ4EuQ*)0;
						i_4 = ((NI)0);
						T24_ = (*(*seat_p0).dangerGeometry).perimeter.len;
						L_2 = T24_;
						{
							while (1) {
								NI TM__fw0EGWK0CbR9aJ84zaF6cBg_300;
								NI TM__fw0EGWK0CbR9aJ84zaF6cBg_301;
								if (!(i_4 < L_2)) goto LA26;
								if (i_4 < 0 || i_4 >= (*(*seat_p0).dangerGeometry).perimeter.len){ raiseIndexError2(i_4,(*(*seat_p0).dangerGeometry).perimeter.len-1); goto BeforeRet_;
								}
								offset_1 = (&(*(*seat_p0).dangerGeometry).perimeter.p->data[i_4]);
								if (nimAddInt(origin_1.Field0, (*offset_1).Field0, &TM__fw0EGWK0CbR9aJ84zaF6cBg_300)) { raiseOverflow(); goto BeforeRet_;
								};
								if (nimAddInt(origin_1.Field1, (*offset_1).Field1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_301)) { raiseOverflow(); goto BeforeRet_;
								};
								castRay__OOZsrcZshellZbody95nav_u2075(seat_p0, origin_1, (((*(*seat_p0).dangerGeometry).kernel).p) ? ((*(*seat_p0).dangerGeometry).kernel.p->data) : NIM_NIL, (*(*seat_p0).dangerGeometry).kernel.len, (*(*seat_p0).dangerGeometry).radius, (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_300), (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_301));
								if (NIM_UNLIKELY(*nimErr_)) goto BeforeRet_;
								i_4 += ((NI)1);
								{
									NI T29_;
									T29_ = (*(*seat_p0).dangerGeometry).perimeter.len;
									if (!!((T29_ == L_2))) goto LA30_;
									failedAssertImpl__stdZassertions_u234(TM__fw0EGWK0CbR9aJ84zaF6cBg_302);
									if (NIM_UNLIKELY(*nimErr_)) goto BeforeRet_;
								}
LA30_: ;
							} LA26: ;
						}
					}
				}
LA14_: ;
				closeRange_1 = ((((NI)190) <= (*seat_p0).dangerRangePx) ? ((NI)190) : (*seat_p0).dangerRangePx);
				if (nimAddInt(closeRange_1, ((NI)8), &TM__fw0EGWK0CbR9aJ84zaF6cBg_303)) { raiseOverflow(); goto BeforeRet_;
				};
				if (nimSubInt((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_303), ((NI)1), &TM__fw0EGWK0CbR9aJ84zaF6cBg_304)) { raiseOverflow(); goto BeforeRet_;
				};
				closeCells_1 = (NI)(((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_304)) / (((NI)8)));
				if (nimMulInt(closeRange_1, closeRange_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_305)) { raiseOverflow(); goto BeforeRet_;
				};
				closeSquared_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_305);
				{
					NI gy_1;
					NI colontmp_;
					NI colontmp__2;
					NI TM__fw0EGWK0CbR9aJ84zaF6cBg_306;
					NI T33_;
					NI TM__fw0EGWK0CbR9aJ84zaF6cBg_307;
					NI TM__fw0EGWK0CbR9aJ84zaF6cBg_308;
					NI res_1;
					gy_1 = (NI)0;
					colontmp_ = (NI)0;
					colontmp__2 = (NI)0;
					if (nimSubInt(origin_1.Field1, closeCells_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_306)) { raiseOverflow(); goto BeforeRet_;
					};
					colontmp_ = ((((NI)0) >= (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_306)) ? ((NI)0) : (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_306));
					T33_ = (NI)0;
					T33_ = gridHeight__OOZsrcZshellZbody95map_u141(map_p1);
					if (NIM_UNLIKELY(*nimErr_)) goto BeforeRet_;
					if (nimSubInt(T33_, ((NI)1), &TM__fw0EGWK0CbR9aJ84zaF6cBg_307)) { raiseOverflow(); goto BeforeRet_;
					};
					if (nimAddInt(origin_1.Field1, closeCells_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_308)) { raiseOverflow(); goto BeforeRet_;
					};
					colontmp__2 = (((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_307) <= (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_308)) ? (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_307) : (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_308));
					res_1 = colontmp_;
					{
						while (1) {
							NI TM__fw0EGWK0CbR9aJ84zaF6cBg_320;
							if (!(res_1 <= colontmp__2)) goto LA35;
							gy_1 = ((NI) (res_1));
							{
								NI gx_1;
								NI colontmp__3;
								NI colontmp__4;
								NI TM__fw0EGWK0CbR9aJ84zaF6cBg_309;
								NI T37_;
								NI TM__fw0EGWK0CbR9aJ84zaF6cBg_310;
								NI TM__fw0EGWK0CbR9aJ84zaF6cBg_311;
								NI res_2;
								gx_1 = (NI)0;
								colontmp__3 = (NI)0;
								colontmp__4 = (NI)0;
								if (nimSubInt(origin_1.Field0, closeCells_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_309)) { raiseOverflow(); goto BeforeRet_;
								};
								colontmp__3 = ((((NI)0) >= (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_309)) ? ((NI)0) : (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_309));
								T37_ = (NI)0;
								T37_ = gridWidth__OOZsrcZshellZbody95map_u138(map_p1);
								if (NIM_UNLIKELY(*nimErr_)) goto BeforeRet_;
								if (nimSubInt(T37_, ((NI)1), &TM__fw0EGWK0CbR9aJ84zaF6cBg_310)) { raiseOverflow(); goto BeforeRet_;
								};
								if (nimAddInt(origin_1.Field0, closeCells_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_311)) { raiseOverflow(); goto BeforeRet_;
								};
								colontmp__4 = (((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_310) <= (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_311)) ? (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_310) : (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_311));
								res_2 = colontmp__3;
								{
									while (1) {
										tyTuple__1v9bKyksXWMsm0vNwmZ4EuQ center_1;
										tyTuple__1v9bKyksXWMsm0vNwmZ4EuQ T40_;
										NI dx_1;
										NI TM__fw0EGWK0CbR9aJ84zaF6cBg_312;
										NI dy_1;
										NI TM__fw0EGWK0CbR9aJ84zaF6cBg_313;
										NI TM__fw0EGWK0CbR9aJ84zaF6cBg_319;
										if (!(res_2 <= colontmp__4)) goto LA39;
										gx_1 = ((NI) (res_2));
										T40_.Field0 = gx_1;
										T40_.Field1 = gy_1;
										center_1 = cellCenter__OOZsrcZshellZbody95map_u524(T40_);
										if (NIM_UNLIKELY(*nimErr_)) goto BeforeRet_;
										if (nimSubInt(center_1.Field0, (*source_1).Field0, &TM__fw0EGWK0CbR9aJ84zaF6cBg_312)) { raiseOverflow(); goto BeforeRet_;
										};
										dx_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_312);
										if (nimSubInt(center_1.Field1, (*source_1).Field1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_313)) { raiseOverflow(); goto BeforeRet_;
										};
										dy_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_313);
										{
											NI TM__fw0EGWK0CbR9aJ84zaF6cBg_314;
											NI TM__fw0EGWK0CbR9aJ84zaF6cBg_315;
											NI TM__fw0EGWK0CbR9aJ84zaF6cBg_316;
											NI T45_;
											NI TM__fw0EGWK0CbR9aJ84zaF6cBg_317;
											NI TM__fw0EGWK0CbR9aJ84zaF6cBg_318;
											if (nimMulInt(dx_1, dx_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_314)) { raiseOverflow(); goto BeforeRet_;
											};
											if (nimMulInt(dy_1, dy_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_315)) { raiseOverflow(); goto BeforeRet_;
											};
											if (nimAddInt((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_314), (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_315), &TM__fw0EGWK0CbR9aJ84zaF6cBg_316)) { raiseOverflow(); goto BeforeRet_;
											};
											if (!((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_316) <= closeSquared_1)) goto LA43_;
											T45_ = (NI)0;
											T45_ = gridWidth__OOZsrcZshellZbody95map_u138(map_p1);
											if (NIM_UNLIKELY(*nimErr_)) goto BeforeRet_;
											if (nimMulInt(gy_1, T45_, &TM__fw0EGWK0CbR9aJ84zaF6cBg_317)) { raiseOverflow(); goto BeforeRet_;
											};
											if (nimAddInt((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_317), gx_1, &TM__fw0EGWK0CbR9aJ84zaF6cBg_318)) { raiseOverflow(); goto BeforeRet_;
											};
											if ((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_318) < 0 || (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_318) >= (*seat_p0).danger.values.len){ raiseIndexError2((NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_318),(*seat_p0).danger.values.len-1); goto BeforeRet_;
											}
											pluseq___OOZOOZOOZOOZOOZOnimbyZpkgsZbumpyZsrcZbumpy_u130((&(*seat_p0).danger.values.p->data[(NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_318)]), 0.5f);
										}
LA43_: ;
										if (nimAddInt(res_2, ((NI)1), &TM__fw0EGWK0CbR9aJ84zaF6cBg_319)) { raiseOverflow(); goto BeforeRet_;
										};
										res_2 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_319);
									} LA39: ;
								}
							}
							if (nimAddInt(res_1, ((NI)1), &TM__fw0EGWK0CbR9aJ84zaF6cBg_320)) { raiseOverflow(); goto BeforeRet_;
							};
							res_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_320);
						} LA35: ;
					}
				}
				i_2 += ((NI)1);
				eqdestroy___OOZsrcZshellZbody95nav_u972(cache_1);
			} LA12: ;
		}
	}
	(*seat_p0).danger.maximum = 0.0f;
	{
		NF32* value_2;
		NI i_5;
		NI L_3;
		NI T47_;
		value_2 = (NF32*)0;
		i_5 = ((NI)0);
		T47_ = (*seat_p0).danger.values.len;
		L_3 = T47_;
		{
			while (1) {
				if (!(i_5 < L_3)) goto LA49;
				if (i_5 < 0 || i_5 >= (*seat_p0).danger.values.len){ raiseIndexError2(i_5,(*seat_p0).danger.values.len-1); goto BeforeRet_;
				}
				value_2 = (&(*seat_p0).danger.values.p->data[i_5]);
				{
					if (!NIM_FALSE) goto LA52_;
					stareq___OOZOOZOOZOOZOOZOnimbyZpkgsZchromaZsrcZchromaZblends_u46(value_2, 1.0f);
				}
LA52_: ;
				(*seat_p0).danger.maximum = max__system_u1202((*seat_p0).danger.maximum, (*value_2));
				i_5 += ((NI)1);
				{
					NI T56_;
					T56_ = (*seat_p0).danger.values.len;
					if (!!((T56_ == L_3))) goto LA57_;
					failedAssertImpl__stdZassertions_u234(TM__fw0EGWK0CbR9aJ84zaF6cBg_321);
					if (NIM_UNLIKELY(*nimErr_)) goto BeforeRet_;
				}
LA57_: ;
			} LA49: ;
		}
	}
	(*seat_p0).dangerTick = tick_p3;
	}BeforeRet_: ;
	popFrame();
}